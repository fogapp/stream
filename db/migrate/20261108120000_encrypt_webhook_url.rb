# frozen_string_literal: true

# The outgoing webhook's address carries its secret in the path, and is now
# encrypted (AppSetting encrypts :webhook_url). support_unencrypted_data
# reads an existing plaintext one fine, but it stays plaintext on disk until
# the next save: re-saved here, encrypted. A model of its own, so a later
# change to AppSetting can't break this. Release phase only, as every
# migration (CLAUDE.md › Deployment). No column changes: encrypted, the
# address is a longer string in the same column. The old release, for the
# moment of the swap it still runs, would read the ciphertext as the address
# — a webhook it sent then would fail (WebhookJob says so), not leak.
class EncryptWebhookUrl < ActiveRecord::Migration[8.1]
  class Setting < ActiveRecord::Base
    self.table_name = "app_settings"
    encrypts :webhook_url
  end

  def up
    Setting.reset_column_information
    Setting.where.not(webhook_url: nil).find_each(&:encrypt)
  end

  def down
    Setting.where.not(webhook_url: nil).find_each(&:decrypt)
  end
end
