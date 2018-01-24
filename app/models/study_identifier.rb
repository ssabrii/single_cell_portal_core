##
# StudyIdentifier: collection to keep a running tally of all used ids.  Also provides a shorter way to retrieve a study
# rather than by using study.url_safe_name
##

class StudyIdentifier
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :study

  field :identifier, type: String

  before_validation :generate_identifier, on: :create
  validates_uniqueness_of :identifier

  PREFIX = 'SCP'

  private

  def generate_identifier
    current_count = StudyIdentifier.count + 1
    self.identifier = "#{PREFIX}#{current_count}"
  end
end