# frozen_string_literal: true

class Api::V1::Timelines::HomeController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }, only: [:show]
  before_action :require_user!, only: [:show]
  after_action :insert_pagination_headers, unless: -> { @statuses.empty? }

  def show
    with_read_replica do
      @statuses = load_statuses
      @relationships = StatusRelationshipsPresenter.new(@statuses, current_user&.account_id)
    end

    # trigger an asynchronous save of the store at on average one in
    # 10 accesses. This will need tuning for large instances.
    if 0 == rand(10)
      Thread.new do
        save_result = Net::HTTP.post_form(URI('http://127.0.0.1:4280/store/state'), 'data' => 'saved')
        puts "Triggered wispwot save"
        puts save_result.body
      end
    end

    require 'net/http'
    ownkey_request = Net::HTTP.get_response(URI('http://127.0.0.1:4280/key/' + current_user&.account_id.to_s))
    # if the own id does not exist yet, create it
    if not ownkey_request.is_a?(Net::HTTPSuccess)
      Net::HTTP.post_form(URI('http://127.0.0.1:4280/trust/d6.gnutella2.info'), '100' => current_user&.account_id.to_s)
      ownkey_request = Net::HTTP.get_response(URI('http://127.0.0.1:4280/key/' + current_user&.account_id.to_s))
    end
    ownkey = ownkey_request.body

    @statuses_filtered = @statuses.select do |status|
      # local ids receive trust when they are seen in the home timeline
      if status.uri.start_with?("http://d6.gnutella2.info/users/")
        Net::HTTP.post_form(URI('http://127.0.0.1:4280/addtrust/' + current_user&.account_id.to_s), '5' => status.account_id.to_s)
        true
      else
        # accounts from other instances are only shown when they have existing trust
        account_request = Net::HTTP.get_response(URI('http://127.0.0.1:4280/key/' + status.account_id.to_s))
        if account_request.is_a?(Net::HTTPSuccess)
          account_key = account_request.body
          result = Net::HTTP.get_response(URI('http://127.0.0.1:4280/score/ownkey/' + ownkey + '/otherkey/' + account_key))
          if ((result.body && result.body.to_i >= 0) if result.is_a?(Net::HTTPSuccess))
            if status.in_reply_to_account_id
              # add trust to account which received a reply: this
              # makes accounts visible that trusted people interact
              # with.
              Net::HTTP.post_form(URI('http://127.0.0.1:4280/addtrust/' + status.account_id.to_s), '2' => status.in_reply_to_account_id.to_s)
            end
            # known ID: show
            true
          end
        else
          # unknown ID: do not show
          false
        end
      end
    end

    render json: @statuses_filtered,
           each_serializer: REST::StatusSerializer,
           relationships: @relationships,
           status: account_home_feed.regenerating? ? 206 : 200
  end

  private

  def load_statuses
    cached_home_statuses
  end

  def cached_home_statuses
    cache_collection home_statuses, Status
  end

  def home_statuses
    account_home_feed.get(
      limit_param(DEFAULT_STATUSES_LIMIT),
      params[:max_id],
      params[:since_id],
      params[:min_id]
    )
  end

  def account_home_feed
    HomeFeed.new(current_account)
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def pagination_params(core_params)
    params.slice(:local, :limit).permit(:local, :limit).merge(core_params)
  end

  def next_path
    api_v1_timelines_home_url pagination_params(max_id: pagination_max_id)
  end

  def prev_path
    api_v1_timelines_home_url pagination_params(min_id: pagination_since_id)
  end

  def pagination_max_id
    @statuses.last.id
  end

  def pagination_since_id
    @statuses.first.id
  end
end
