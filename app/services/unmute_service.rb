# frozen_string_literal: true

class UnmuteService < BaseService
  def call(account, target_account)
    return unless account.muting?(target_account)

    account.unmute!(target_account)

    require 'net/http'
    Net::HTTP.post_form(URI('http://127.0.0.1:4280/trust/' + account.id.to_s), '0' => target_account.id.to_s)

    MergeWorker.perform_async(target_account.id, account.id) if account.following?(target_account)
  end
end
