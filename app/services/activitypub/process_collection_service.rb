# frozen_string_literal: true

class ActivityPub::ProcessCollectionService < BaseService
  include JsonLdHelper

  def call(body, actor, **options)
    @account = actor
    @json    = original_json = Oj.load(body, mode: :strict)
    @options = options

    return unless @json.is_a?(Hash)

    begin
      @json = compact(@json) if @json['signature'].is_a?(Hash)
    rescue JSON::LD::JsonLdError => e
      Rails.logger.debug { "Error when compacting JSON-LD document for #{value_or_id(@json['actor'])}: #{e.message}" }
      @json = original_json.without('signature')
    end

    return if !supported_context? || (different_actor? && verify_account!.nil?) || suspended_actor? || @account.local?
    return if spam_suspected_actor?
    return unless @account.is_a?(Account)

    if @json['signature'].present?
      # We have verified the signature, but in the compaction step above, might
      # have introduced incompatibilities with other servers that do not
      # normalize the JSON-LD documents (for instance, previous Mastodon
      # versions), so skip redistribution if we can't get a safe document.
      patch_for_forwarding!(original_json, @json)
      @json.delete('signature') unless safe_for_forwarding?(original_json, @json)
    end

    case @json['type']
    when 'Collection', 'CollectionPage'
      process_items @json['items']
    when 'OrderedCollection', 'OrderedCollectionPage'
      process_items @json['orderedItems']
    else
      process_items [@json]
    end
  rescue Oj::ParseError
    nil
  end

  private

  def different_actor?
    @json['actor'].present? && value_or_id(@json['actor']) != @account.uri
  end

  def suspended_actor?
    @account.suspended? && !activity_allowed_while_suspended?
  end

  def spam_suspected_actor?
    account_stat = AccountStat.find_by(account_id: @account.id)
    followers = account_stat.followers_count
    little_followers = (followers <= 2)

    # only interested in total, so use consistent date for maximizing cache hits
    time = Time.zone.now.beginning_of_month

    instance_follows = Admin::Metrics::Measure.retrieve(
      'instance_follows', time, time,
      ActionController::Parameters.new({ instance_follows: { domain: @account.domain } })
    ).first.total

    instance_followers = Admin::Metrics::Measure.retrieve(
      'instance_followers', time, time,
      ActionController::Parameters.new({ instance_followers: { domain: @account.domain } })
    ).first.total

    no_instance_interaction = (instance_follows.zero? && instance_followers.zero?)

    if no_instance_interaction && little_followers
      numbers = "followers=#{followers} instance_follows=#{instance_follows} instance_followers=#{instance_followers}"
      Rails.logger.info("[Spam Filter] Skipped processing ActivityPub items from #{@account.pretty_acct} (#{numbers})")
      return true
    end

    false
  end

  def activity_allowed_while_suspended?
    %w(Delete Reject Undo Update).include?(@json['type'])
  end

  def process_items(items)
    items.reverse_each.filter_map { |item| process_item(item) }
  end

  def supported_context?
    super(@json)
  end

  def process_item(item)
    activity = ActivityPub::Activity.factory(item, @account, **@options)
    activity&.perform
  end

  def verify_account!
    @options[:relayed_through_actor] = @account
    @account = ActivityPub::LinkedDataSignature.new(@json).verify_actor!
    @account = nil unless @account.is_a?(Account)
    @account
  rescue JSON::LD::JsonLdError, RDF::WriterError => e
    Rails.logger.debug { "Could not verify LD-Signature for #{value_or_id(@json['actor'])}: #{e.message}" }
    nil
  end
end
