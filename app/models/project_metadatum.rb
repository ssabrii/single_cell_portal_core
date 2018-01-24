##
#
# Human Cell Atlas formatted project relating to analyses
# https://github.com/HumanCellAtlas/metadata-schema/blob/master/json_schema/project.json
#
##

class ProjectMetadatum < HCAMetadatum
  include Mongoid::Document
  include Mongoid::Timestamps

  # field definitions
  belongs_to :study
  field :payload, type: Hash # actual HCA JSON payload
  field :version, type: String # string version number indicating an HCA release

  validates_presence_of :payload, :version
  validates_uniqueness_of :slug

  before_validation :set_slug, on: :create

  SLUG_PREFIX = 'SCP'

  # HCA-compatible project identifier (unique URL across all instances of the portal)
  def project_identifier
    opts = ActionMailer::Base.default_url_options
    "#{opts[:protocol]}://#{opts[:host]}/single_cell/study/#{self.slug}"
  end

  def entity_name
    'project'
  end

  def entity_filename
    self.entity_name + '.json'
  end
end