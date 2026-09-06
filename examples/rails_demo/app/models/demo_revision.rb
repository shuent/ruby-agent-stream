class DemoRevision < ApplicationRecord
  def self.token
    first_or_create!(token: SecureRandom.uuid).token
  end

  def self.invalidate!
    first_or_create!(token: SecureRandom.uuid).update!(token: SecureRandom.uuid)
  end
end
