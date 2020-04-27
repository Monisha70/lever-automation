# frozen_string_literal: true

require 'method_source'
require_relative '../config/config'
require_relative 'util'
require_relative 'log'
require_relative 'client'
require_relative '../config/rules'

class Controller

  def initialize
    @log = Log.new
    @client = Client.new(ENV['LKEY'], @log)
  end
  
  def client
    @client
  end
  
  def log
    @log
  end

  def summarise_opportunities
    summary = Hash.new(0)
    contacts = Hash.new(0)
    tagable = Hash.new(0)
    untagable = Hash.new(0)
    
    client.process_paged_result(OPPORTUNITIES_URL, {archived: false, expand: ['applications','stage','sourcedBy','owner']}, 'active opportunities') { |opp|
    
      contacts[opp['contact']] += 1
      summary[:opportunities] += 1
      summary[:unique_contacts] += 1 if contacts[opp['contact']] == 1
      summary[:contacts_with_duplicates] += 1 if contacts[opp['contact']] == 2
      summary[:contacts_with_3_plus] += 1 if contacts[opp['contact']] == 3

      location = location_from_tags(opp) if opp['applications'].length == 0
      summary[:unassigned_leads_aka_opportunities_without_posting] += 1 if opp['applications'].length == 0
      summary[:unassigned_leads_with_detected_location] += 1 if opp['applications'].length == 0 && !location.nil?
      summary[:unassigned_leads_without_detected_location] += 1 if opp['applications'].length == 0 && location.nil?

      # puts location[:name] if opp['applications'].length == 0 && !location.nil?
      tagable['unassigned_tagable_to_' + location[:name]] += 1 if opp['applications'].length == 0 && !location.nil?
      tagable['unassigned_tagable_owned_by_' + (opp.dig('owner','name') || '')] += 1 if opp['applications'].length == 0 && !location.nil?
      tagable['unassigned_tagable_sourced_by_' + (opp.dig('sourcedBy','name') || '')] += 1 if opp['applications'].length == 0 && !location.nil?
      
      untagable['untagable_owned_by_' + (opp.dig('owner','name') || '')] += 1 if opp['applications'].length == 0 && location.nil?
      untagable['untagable_sourced_by_' + (opp.dig('sourcedBy','name') || '')] += 1 if opp['applications'].length == 0 && location.nil?
      
      summary[:cohort_applications] += 1 if Util.has_application(opp) && Util.is_cohort_app(opp)
      summary[:team_applications] += 1 if Util.has_application(opp) && !Util.is_cohort_app(opp)

      summary[:leads_assigned_to_cohort_posting] += 1 if opp['applications'].length > 0 && opp['applications'][0]['type'] != 'posting' && Util.is_cohort_app(opp)
      summary[:leads_assigned_to_team_posting] += 1 if opp['applications'].length > 0 && opp['applications'][0]['type'] != 'posting' && !Util.is_cohort_app(opp)
      
      if summary[:opportunities] % 500 == 0
        # log.log(JSON.pretty_generate(contacts))
        puts JSON.pretty_generate(summary)
        puts JSON.pretty_generate(tagable)
        puts JSON.pretty_generate(untagable)
      end
    }
    log.log(JSON.pretty_generate(summary))
    log.log(JSON.pretty_generate(tagable))
    log.log(JSON.pretty_generate(untagable))
  end

  def process_opportunities
    summary = Hash.new(0)
    contacts = Hash.new(0)

    client.batch_updates

    client.process_paged_result(OPPORTUNITIES_URL, {archived: false, expand: ['applications','stage','sourcedBy','owner']}, 'active opportunities') { |opp|
    
      contacts[opp['contact']] += 1
      summary[:opportunities] += 1
      summary[:unique_contacts] += 1 if contacts[opp['contact']] == 1
      summary[:contacts_with_duplicates] += 1 if contacts[opp['contact']] == 2
      summary[:contacts_with_3_plus] += 1 if contacts[opp['contact']] == 3

      result = process_opportunity(opp)
      
      summary[:sent_webhook] += 1 if result['sent_webhook']
      summary[:assigned_to_job] += 1 if result['assigned_to_job']
      summary[:added_source_tag] += 1 if result['added_source_tag']

      # log.log(JSON.pretty_generate(summary)) if summary[:opportunities] % 500 == 0
      log.log("Processed #{summary[:opportunities]} opportunities (#{summary[:unique_contacts]} contacts); #{summary[:sent_webhook]} changed; #{summary[:assigned_to_job]} assigned to job") if summary[:opportunities] % 1000 == 0
    }
    client.batch_updates(false)

    log.log(JSON.pretty_generate(summary))
  end

  # process a single opportunity
  # apply changes & trigger webhook as necessary
  def process_opportunity(opp)
    result = {}
    # log('Processing Opportunity: ' + opp['id'])
    log.log_prefix(opp['id'] + ': ')

    # checks lastInteractionAt and tag checksum, creating checksum tag if necessary
    last_update = latest_change(opp)
    # should notify of change based on state before we executed?
    notify = last_update[:time] > last_webhook_change(opp) + 100

    if check_no_posting(opp)
      # if we added to a job then reload as tags etc will have changed
      opp.merge!(client.get_opportunity(opp['id']))
      result['assigned_to_job'] = true
    end
    result['added_source_tag'] if tag_source_from_application(opp)
    
    summarise_feedbacks(opp)

    # detect_duplicate_opportunities(opp)

    [tags_have_changed?(opp), links_have_changed?(opp)].each{ |update|
      unless update.nil?
        last_update = update
        notify = true
      end
    }

    if notify
      # send webhook of change
      notify_of_change(opp, last_update)
      result['sent_webhook'] = true
    elsif opp['_addedNoteTimestamp']
      # we didn't have a change to notify, but we added one or more notes
      # which will update lastInteractionAt
      # so update LAST_CHANGE_TAG to avoid falsely detecting update next time
      update_changed_tag(opp, opp['_addedNoteTimestamp'])
    end

    update_bot_metadata(opp)
    client.commit_opp(opp)

    log.pop_log_prefix
    result
  end

  # process leads not assigned to any posting
  # ~~
  # Note slight confusion between Lever interface vs API:
  # - Leads not assigned to a job posting show up in Lever as candidates with "no opportunity", but are returned in the API as opportunities without an application
  # - Leads assigned to a job posting show up in Lever as opportunities - potentially multiple per candidate. These show up in the API as applications against the opportunity - even when no actual application submitted
  def check_no_posting(opp)
    return if opp["applications"].count > 0
    location = location_from_tags(opp)
    if location.nil?
      # unable to determine target location from tags
      client.add_tag(opp, TAG_ASSIGN_TO_LOCATION_NONE_FOUND) unless opp['tags'].include?(TAG_ASSIGN_TO_LOCATION_NONE_FOUND)
      nil
    else
      client.remove_tag(opp, TAG_ASSIGN_TO_LOCATION_NONE_FOUND) if opp['tags'].include?(TAG_ASSIGN_TO_LOCATION_NONE_FOUND)
      client.add_tag(opp, TAG_ASSIGN_TO_LOCATION_PREFIX + location[:name])
      client.add_tag(opp, TAG_ASSIGNED_TO_LOCATION)
      # add_note(opp, 'Assigned to cohort job: ' + location[:name] + ' based on tags')
      client.add_candidate_to_posting(opp["id"], location[:posting_id])
      true
    end
  end
  
  # record change detected and send webhook
  def notify_of_change(opp, last_update)
    unless opp['applications'].length == 0
      send_webhook(opp, last_update[:time])
      client.add_note(opp, 'Updated reporting data after detecting ' + last_update[:source])
    end
    update_changed_tag(opp)
  end
  
  def send_webhook(opp, update_time)
    log.log("Sending webhook - change detected") #: " + opp["id"])
    OPPORTUNITY_CHANGED_WEBHOOK_URLS.each {|url|
      p = fork {HTTParty.post(
          url,
          body: {
            # id: '',
            triggeredAt: update_time,
            event: 'candidateOtherChange_EFCustomBot',
            # signature: '',
            # token: '',
            data: {
              candidateId: opp['id'],
              contactId: opp['contact'],
              opportunityId: opp['id']
            }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )}
      Process.detach(p)
    }
  end

  def update_changed_tag(opp, update_time=nil)
    if update_time.nil?
      update_time = client.get_opportunity(opp['id']).fetch('lastInteractionAt', Time.now.to_i*1000)
    end
    set_bot_metadata(opp, ‘last_change_detected’, update_time)
  end
  
  # detect when opportunity was last updated
  # uses current time if we detect tags have changed
  def latest_change(opp)
    [
      {time: opp["lastInteractionAt"], source: 'a new interaction'},
      tags_have_changed?(opp),
      links_have_changed?(opp)
    ].reject {|x| x.nil?}.max_by {|x| x[:time]}
  end

  # detect if tags have changed since we last checked, based on special checksum tag
  def tags_have_changed?(opp)
    checksum = attribute_checksum(opp, 'tags')
    existing = existing_tag_checksum(opp)
    
    if existing != checksum
      set_bot_metadata(opp, 'tag_checksum', checksum)
    end

    {
      time: Time.now.to_i*1000,
      source: "tags updated\n#" + opp['tags'].sort.reject {|t| t.start_with?(BOT_TAG_PREFIX)}.map {|t| t.gsub(/[ \(\):]/, '-').sub('🤖-[auto]-', '')}.join(' #')
    } if existing != checksum && !existing.nil?
  end
  
  # detect if links have changed since we last checked, based on special checksum link
  def links_have_changed?(opp)
    checksum = attribute_checksum(opp, 'links')
    existing = existing_link_checksum(opp)
    
    if existing != checksum
      set_bot_metadata(opp, 'link_checksum', checksum)
    end

    {
      time: Time.now.to_i*1000,
      source: "links updated\n📎 " + opp['links'].sort{|a,b| a.sub(/[a-z]+:\/\//,'') <=> b.sub(/[a-z]+:\/\//,'')}.reject {|t| t.start_with?(BOT_LINK_PREFIX)}.join("\n📎 ")
    } if existing != checksum && !existing.nil?
  end
  
  # calculate checksum for tags/links
  # - excludes bot-applied
  def attribute_checksum(opp, type)
    Digest::MD5.hexdigest(opp[type].reject {|t|
      t.start_with?(type == 'tags' ? BOT_TAG_PREFIX : BOT_LINK_PREFIX)
      }.sort.join(";;"))
  end
  
  def existing_tag_checksum(opp)
    bot_metadata(opp)['tag_checksum'] if bot_metadata(opp)['tag_checksum']
    # legacy
    opp['tags'].each { |t|
      if t.start_with? TAG_CHECKSUM_PREFIX
        checksum = t.delete_prefix TAG_CHECKSUM_PREFIX
        set_bot_metadata(opp, 'tag_checksum', checksum)
        return checksum
      end
    }
    nil
  end
  
  def existing_link_checksum(opp)
    bot_metadata(opp)['link_checksum'] if bot_metadata(opp)['link_checksum']
    # legacy
    opp['links'].each { |t|
      if t.start_with? LINK_CHECKSUM_PREFIX
        checksum = t.delete_prefix LINK_CHECKSUM_PREFIX
        set_bot_metadata(opp, 'link_checksum', checksum)
        return checksum
      end
    }
    nil
  end
  
  # detect time of last change that would have triggered a Lever native webhook
  # - either a lever Native webhook (created, stage change or application),
  #   or a webhook we send ourselves via this script (recorded via tag)
  def last_webhook_change(opp)
    (
      [opp["createdAt"], opp["lastAdvancedAt"], bot_metadata(opp)['last_change_detected']] +
      opp["applications"].map {|a| a["createdAt"]} +
      
      # legacy
      (opp["tags"].select {|t| t.start_with? LAST_CHANGE_TAG_PREFIX}.map {|t| Util.datetimestr_to_timestamp(t.delete_prefix(LAST_CHANGE_TAG_PREFIX)) })
    ).reject {|x| x.nil?}.max
  end
  
  # automatically add tag for the opportunity source based on self-reported data in the application
  def tag_source_from_application(opp)
    client.remove_tag(opp, TAG_SOURCE_FROM_APPLICATION_ERROR) if opp['tags'].include? TAG_SOURCE_FROM_APPLICATION_ERROR
    
    # we need an application of type posting, to the cohort (not team job)
    return if !Util.has_application(opp) || !Util.is_cohort_app(opp)
    
    # skip if already applied
    opp['tags'].each {|tag|
      return if tag.start_with?(TAG_SOURCE_FROM_APPLICATION) && tag != TAG_SOURCE_FROM_APPLICATION_ERROR
    }
    
    source = Rules.source_from_application(opp)
    unless source.nil? || source[:source].nil?
      client.add_tag(opp, TAG_SOURCE_FROM_APPLICATION + source[:source])
      client.remove_tag(opp, TAG_SOURCE_FROM_APPLICATION_ERROR) if opp['tags'].include? TAG_SOURCE_FROM_APPLICATION_ERROR
      client.add_note(opp, 'Added tag ' + TAG_SOURCE_FROM_APPLICATION + source[:source] + "\nbecause field \"" + source[:field] + "\"\nis \"" + (source[:value].class == Array ?
        source[:value].join('; ') :
        source[:value]) + '"')
    else
      client.add_tag(opp, TAG_SOURCE_FROM_APPLICATION_ERROR) if !opp['tags'].include? TAG_SOURCE_FROM_APPLICATION_ERROR
    end
    true
  end
  
  def summarise_feedbacks(opp)
    if opp['lastInteractionAt'] > (feedback_summarised_at(opp) || 0)
      # summarise each feedback
      client.feedback_for_opp(opp).each {|f|
        link = one_feedback_summary_link(f)
        next if opp['links'].include?(link)
        client.remove_links_with_prefix(opp, one_feedback_summary_link_prefix(f))
        client.add_links(opp, link)
      }
      update_feedback_summary_time(opp)
    end

    all_link = all_feedback_summary_link(opp)
    unless opp['links'].include?(all_link)
      client.remove_links_with_prefix(opp, all_feedback_summary_link_prefix)
    end
    unless all_link.nil?
      client.add_links(opp, all_link)
    end
  end
  
  def feedback_summarised_at(opp)
    fsa = bot_metadata(opp)['feedback_summarised_at']
    return if fsa.nil?
    
    rules_checksum, ts = fsa.split(':')
    rules_checksum == feedback_rules_checksum ? ts : nil
  end
  
  def update_feedback_summary_time(opp)
    set_bot_metadata('feedback_summarised_at', "#{feedback_rules_checksum}:#{opp['lastInteractionAt']}")
  end
  
  def feedback_rules_checksum
    @feedback_rules_checksum ||= Digest::MD5.hexdigest(Rules.method('summarise_one_feedback').source)
  end
  
  def one_feedback_summary_link_prefix(f)
    AUTO_LINK_PREFIX + "feedback/#{f['id']}/"
  end
  
  def one_feedback_summary_link(f)
    feedback_summary_link_prefix(f) + '?' + URI.encode_www_form({
        'title': f['text'],
        'user': f['user'],
        'createdAt': f['createdAt'],
        'completedAt': f['completedAt']
      }.merge(Rules.summarise_one_feedback(f).reject{|k,v| v.nil?}.sort)
    )
  end
  
  def all_feedback_summary_link_prefix
    AUTO_LINK_PREFIX + "feedback/all/"
  end
  
  def all_feedback_summary_link(opp)
    feedback_data = opp['links'].select { |l|
        l.start_with? AUTO_LINK_PREFIX + 'feedback/'
      }.map { |l|
        URI.decode_www_form(l.sub(/[^?]*\?/, '')).to_h
      }
    return unless feedback_data.any?
    
    summary = Rules.summarise_all_feedback(feedback_data)
    return unless summary.any?
    
    all_feedback_summary_link_prefix + '?' + URI.encode_www_form(summary)
  end
  
  # determine intended cohort location from lead tags
  def location_from_tags(opp)
    opp["tags"].each { |tag|
      COHORT_JOBS.each { |cohort|
        return cohort if tag.downcase.include?(cohort[:name])
      }
    }
    nil
  end

  def bot_metadata(opp)
    opp['_bot_metadata'] ||= URI.decode_www_form((opp['links'].select {|l| l.start_with? BOT_METADATA_PREFIX }.first || '').sub(/[^?]*\?/, '')).to_h
  end
  
  def set_bot_metadata(opp, key, value)
    bot_metadata(opp)
    opp['_bot_metadata'][key] = value
  end
  
  def commit_bot_metadata(opp)
    return unless (opp['_bot_metadata'] || {}).any?
    link = BOT_METADATA_PREFIX + '?' + URI.encode_www_form(opp['_bot_metadata'].sort)
    return if opp['links'].include? link
    
    client.remove_links_with_prefix(opp, BOT_METADATA_PREFIX)
    client.add_links(opp, link)
    
    # tidy legacy
    client.remove_tags_with_prefix(opp, TAG_CHECKSUM_PREFIX)
    client.remove_tags_with_prefix(opp, LAST_CHANGE_TAG_PREFIX)
    client.remove_links_with_prefix(opp, LINK_CHECKSUM_PREFIX)
  end

  # TEMP
  
  # detect duplicate opportunities for a candidate
  def detect_duplicate_opportunities(opp)
    client.remove_tags_with_prefix(opp, TAG_DUPLICATE_OPPS_PREFIX) if opp["applications"].count < 2
    posting_ids = opp["applications"].map {|a| a["posting"] || 'none'}
    duplicates = Util.dup_hash(posting_ids)
    # multiple opps, same position
    client.add_tag(opp, TAG_DUPLICATE_OPPS_PREFIX + " same posting") if duplicates.length > 0
    # multiple opps, for different positions
    client.add_tag(opp, TAG_DUPLICATE_OPPS_PREFIX + " different posting") if posting_ids.reject {|p| p == 'none' }.uniq.length > 1
    # one or more opps for a position, as well as a lead with no job position assigned
    client.add_tag(opp, TAG_DUPLICATE_OPPS_PREFIX + " without posting") if posting_ids.reject {|p| p == 'none' }.length > 0 && posting_ids.include?("none")
  end

  def opportunities_without_posting
    log_string = 'opportunities_without_posting'
    params = {}
    arr = []
    tags = Hash.new(0)
    result = HTTParty.get(OPPORTUNITIES_URL + Util.to_query(params), basic_auth: auth)
    result.fetch('data').each { |o|
      next if o["applications"].count > 0
      arr += [{id: o["id"], tags: o["tags"]}]
      o["tags"].each { |tag| tags[tag] += 1 }
    }
    puts "\nOpportunities: " + arr.count.to_s
    puts "\nTags:" + JSON.pretty_generate(tags)
    page = 0
    while result.fetch('hasNext')
      next_batch = result.fetch('next')
      result = api_call_log(log_string, page) do
        HTTParty.get(OPPORTUNITIES_URL + Util.to_query(params.merge(offset: next_batch)), basic_auth: auth)
      end
      result.fetch('data').each { |o|
        next if o["applications"].count > 0
        arr += [{id: o["id"], tags: o["tags"]}]
        o["tags"].each { |tag| tags[tag] += 1 }
      }
      puts "\nOpportunities: " + arr.count.to_s
      puts "\nTags:" + JSON.pretty_generate(tags)
      page += 1
    end
    {opportunities: arr, tags: tags}
  end

  def check_links
    client.process_paged_result(OPPORTUNITIES_URL, {archived: false}, 'checking for links') { |opp|
      puts JSON.pretty_generate(opp) if opp['links'].length > 1
    }
  end

  # fixes

  def fix_auto_assigned_tags
    client.process_paged_result(OPPORTUNITIES_URL, {archived: false, expand: ['applications']}, 'fixing auto-assigned tags for active opportunities') { |opp|
      next if opp['applications'].length == 0
      client.add_tag(opp, TAG_ASSIGNED_TO_LOCATION, true) if opp['applications'][0]['user'] == LEVER_BOT_USER && !opp['tags'].include?(TAG_ASSIGNED_TO_LOCATION)
      client.remove_tag(opp, TAG_SOURCE_FROM_APPLICATION_ERROR) if !Util.has_application(opp) || !Util.is_cohort_app(opp)
    }
  end

  def fix_checksum_links
    client.process_paged_result(OPPORTUNITIES_URL, {archived: false}, 'fixing checksum links for active opportunities') { |opp|
      client.remove_links_with_prefix(opp, AUTO_LINK_PREFIX + 'checksum/')
    }
  end

end
