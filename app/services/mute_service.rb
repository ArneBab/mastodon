# frozen_string_literal: true

class MuteService < BaseService
  def call(account, target_account, notifications: nil, duration: 0)
    return if account.id == target_account.id

    mute = account.mute!(target_account, notifications: notifications, duration: duration)

    require 'net/http'
    Net::HTTP.post_form(URI('http://127.0.0.1:4280/trust/' + account.id.to_s), '-1' => target_account.id.to_s)

    if mute.hide_notifications?
      BlockWorker.perform_async(account.id, target_account.id)
    else
      MuteWorker.perform_async(account.id, target_account.id)
    end

    DeleteMuteWorker.perform_at(duration.seconds, mute.id) if duration != 0

    mute
  end
end
