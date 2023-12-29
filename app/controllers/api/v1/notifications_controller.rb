# frozen_string_literal: true

class Api::V1::NotificationsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:notifications' }, except: [:clear, :dismiss]
  before_action -> { doorkeeper_authorize! :write, :'write:notifications' }, only: [:clear, :dismiss]
  before_action :require_user!
  after_action :insert_pagination_headers, only: :index

  DEFAULT_NOTIFICATIONS_LIMIT = 40

  def index
    with_read_replica do
      @notifications = load_notifications
      @relationships = StatusRelationshipsPresenter.new(target_statuses_from_notifications, current_user&.account_id)
    end

    require 'pp'
    require 'net/http'
    puts "notifications index"
    pp(@notifications)
    ownkey_request = Net::HTTP.get_response(URI('http://127.0.0.1:4280/key/' + current_user&.account_id.to_s))
    # if the own id does not exist yet, create it
    pp(ownkey_request)
    if not ownkey_request.is_a?(Net::HTTPSuccess)
      Net::HTTP.post_form(URI('http://127.0.0.1:4280/trust/d6.gnutella2.info'), '100' => current_user&.account_id.to_s)
      ownkey_request = Net::HTTP.get_response(URI('http://127.0.0.1:4280/key/' + current_user&.account_id.to_s))
      puts "ownkey request"
      pp(ownkey_request)
    end
    ownkey = ownkey_request.body
    puts "ownkey"
    pp(ownkey)

    @notifications_filtered = @notifications.select do |notification|
      # filter only status, polls, update, follow_request, favorite
      puts 'notification.type'
      pp(notification.type)
      if notification.type.in?([:status, :polls, :update, :follow_request, :favorite])
        pp(notification.type)
        account_request = Net::HTTP.get_response(URI('http://127.0.0.1:4280/key/' + notification.from_account_id.to_s))
        if account_request.is_a?(Net::HTTPSuccess)
          account_key = account_request.body
          puts "account_key"
          pp(account_key)
          result = Net::HTTP.get_response(URI('http://127.0.0.1:4280/score/ownkey/' + ownkey + '/otherkey/' + account_key))
          puts "result"
          pp(result)
          puts "result.body"
          pp(result.body)
          (result.body && result.body.to_i >= 0) if result.is_a?(Net::HTTPSuccess)
        else
          false
        end
      else
        true
      end
    end
    render json: @notifications_filtered, each_serializer: REST::NotificationSerializer, relationships: @relationships
  end

  def show
    @notification = current_account.notifications.without_suspended.find(params[:id])
    puts 'notification show'
    render json: @notification, serializer: REST::NotificationSerializer
  end

  def clear
    current_account.notifications.delete_all
    render_empty
  end

  def dismiss
    current_account.notifications.find(params[:id]).destroy!
    render_empty
  end

  private

  def load_notifications
    notifications = browserable_account_notifications.includes(from_account: [:account_stat, :user]).to_a_paginated_by_id(
      limit_param(DEFAULT_NOTIFICATIONS_LIMIT),
      params_slice(:max_id, :since_id, :min_id)
    )

    Notification.preload_cache_collection_target_statuses(notifications) do |target_statuses|
      cache_collection(target_statuses, Status)
    end
  end

  def browserable_account_notifications
    current_account.notifications.without_suspended.browserable(
      types: Array(browserable_params[:types]),
      exclude_types: Array(browserable_params[:exclude_types]),
      from_account_id: browserable_params[:account_id]
    )
  end

  def target_statuses_from_notifications
    @notifications.reject { |notification| notification.target_status.nil? }.map(&:target_status)
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def next_path
    api_v1_notifications_url pagination_params(max_id: pagination_max_id) unless @notifications.empty?
  end

  def prev_path
    api_v1_notifications_url pagination_params(min_id: pagination_since_id) unless @notifications.empty?
  end

  def pagination_max_id
    @notifications.last.id
  end

  def pagination_since_id
    @notifications.first.id
  end

  def browserable_params
    params.permit(:account_id, types: [], exclude_types: [])
  end

  def pagination_params(core_params)
    params.slice(:limit, :account_id, :types, :exclude_types).permit(:limit, :account_id, types: [], exclude_types: []).merge(core_params)
  end
end
