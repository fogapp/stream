# typed: true

# neighbor extends Active Record when it loads (ActiveSupport.on_load).
class ActiveRecord::Base
  extend Neighbor::Model
end
