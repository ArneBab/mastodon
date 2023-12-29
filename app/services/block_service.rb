# frozen_string_literal: true

class BlockService < BaseService
  include Payloadable

  def call(account, target_account)
    return if account.id == target_account.id

    UnfollowService.new.call(account, target_account) if account.following?(target_account)
    UnfollowService.new.call(target_account, account) if target_account.following?(account)
    RejectFollowService.new.call(target_account, account) if target_account.requested?(account)

    block = account.block!(target_account)

    require 'net/http'
    Net::HTTP.post_form(URI('http://127.0.0.1:4280/trust/' + account.id.to_s), '-60' => target_account.id.to_s)


    BlockWorker.perform_async(account.id, target_account.id)
    create_notification(block) if !target_account.local? && target_account.activitypub?
    block
  end

  private

  def create_notification(block)
    ActivityPub::DeliveryWorker.perform_async(build_json(block), block.account_id, block.target_account.inbox_url)
  end

  def build_json(block)
    Oj.dump(serialize_payload(block, ActivityPub::BlockSerializer))
  end
end
