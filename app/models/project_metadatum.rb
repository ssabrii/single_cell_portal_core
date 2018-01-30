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
  validate :validate_payload

  ENTITY_NAME = 'project'
  ENTITY_FILENAME = ENTITY_NAME + '.json'

  ##
  # INSTANCE METHODS
  ##

  # HCA-compatible project identifier (unique URL across all instances of the portal)
  def identifier
    self.study.identifier
  end

  def filename
    ENTITY_FILENAME
  end

  def entity
    ENTITY_NAME
  end

  private

  # check that the automatically generated payload is valid as per schema definitions for this object
  def validate_payload
    begin
      properties = self.parse_definitions(key: 'properties')
      required = self.parse_definitions(key: 'required')
      validated_payload = validate_item_payload(properties, required, self.payload)
      if validated_payload != self.payload
        errors.add(:payload, 'Payload object is invalid')
      end
    rescue => e
      errors.add(:payload, "#{e.message}")
    end
  end
end