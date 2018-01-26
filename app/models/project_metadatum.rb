##
#
# Human Cell Atlas formatted project relating to analyses
# https://github.com/HumanCellAtlas/metadata-schema/blob/master/json_schema/project.json
#
##

class ProjectMetadatum
  include Mongoid::Document
  include Mongoid::Timestamps
  include HCAUtilities

  # field definitions
  belongs_to :study
  field :payload, type: Hash # actual HCA JSON payload
  field :version, type: String # string version number indicating an HCA release

  validates_presence_of :payload, :version
  validates_uniqueness_of :slug

  before_validation :set_slug, on: :create

  ENTITY_NAME = 'project'
  ENTITY_FILENAME = ENTITY_NAME + '.json'

  ##
  # INSTANCE METHODS
  ##

  # HCA-compatible project identifier (unique URL across all instances of the portal)
  def project_identifier
    opts = ActionMailer::Base.default_url_options
    "#{opts[:protocol]}://#{opts[:host]}/single_cell/study/#{self.study.identifier}"
  end

  def filename
    ENTITY_FILENAME
  end

  def entity
    ENTITY_NAME
  end
end