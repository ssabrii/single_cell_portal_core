##
#
# Human Cell Atlas formatted project relating to analyses
# https://github.com/HumanCellAtlas/metadata-schema/blob/master/json_schema/project.json
#
##

class ProjectMetadatum
  include Mongoid::Document
  include Mongoid::Timestamps

  # field definitions
  belongs_to :study
  field :payload, type: Hash # actual HCA JSON payload
  field :version, type: String # string version number indicating an HCA release
  field :name, type: String
  field :slug, type: String

  validates_presence_of :payload, :version
  validates_uniqueness_of :project_identifier

  # HCA-compatible project identifier (unique URL across all instances of the portal)
  def project_identifier
    opts = ActionMailer::Base.default_url_options
    "#{opts[:protocol]}://#{opts[:host]}/single_cell/study/#{self.slug}"
  end

  # root directory for storing metadata schema copies
  def definition_root
    Rails.root.join('data', 'HCA_metadata', self.version)
  end

  # remote endpoint containing metadata schema
  def definition_url
    "https://raw.githubusercontent.com/HumanCellAtlas/metadata-schema/#{self.version}/json_schema/project.json"
  end

  # local filesytem location of copy of JSON schema
  def definition_filepath
    Rails.root.join(self.definition_root, 'project.json')
  end

  # return a parsed JSON object detailing the metadata schema for this object
  def definition_schema
    begin
      # check for local copy first
      if File.exists?(self.definition_filepath)
        existing_schema = File.read(self.definition_filepath)
        JSON.parse(existing_schema)
      else
        Rails.logger.info "#{Time.now}: saving new local copy of #{self.definition_filepath}"
        metadata_schema = RestClient.get self.definition_url
        # write a local copy
        unless Dir.exist?(self.definition_root)
          FileUtils.mkdir_p(self.definition_root)
        end
        new_schema = File.new(self.definition_filepath, 'w+')
        new_schema.write metadata_schema.body
        new_schema.close
        JSON.parse(metadata_schema.body)
      end
    rescue RestClient::ExceptionWithResponse => e
      Rails.logger.error "#{Time.now}: Error retrieving remote HCA Project metadata schema: #{e.message}"
      {error: "Error retrieving definition schema: #{e.message}"}
    rescue JSON::ParserError => e
      Rails.logger.error "#{Time.now}: Error parsing HCA Project metadata schema: #{e.message}"
      {error: "Error parsing definition schema: #{e.message}"}
    end
  end

  # retrieve property or nested field definition information
  # can retrieve info such as require fields, field definitions, property list, etc.
  def definitions(key, field=nil)
    begin
      defs = self.definition_schema[key]
      if field.present?
        defs[field]
      else
        defs
      end
    rescue NoMethodError => e
      field_key = field.present? ? "#{key}/#{field}" : key
      Rails.logger.error "#{Time.now}: Error accessing remote HCA Analysis metadata field definitions for #{field_key}: #{e.message}"
      nil
    end
  end

  # set a value based on the schema definition for a particular field
  def set_value_by_type(definitions, value)
    value_type = definitions['type']
    value_items = definitions['items']
    value_pattern = definitions['pattern']
    case value_type
      when 'string'
        if value_pattern.present?
          if (value =~ Regexp.new(value_pattern).freeze).present?
            value
          else
            raise TypeError.new("#{value} does not conform to the expected format of #{value_pattern}")
          end
        else
          value
        end
      when 'integer'
        value.to_i
      when 'array'
        if value.is_a?(Array)
          value
        elsif value.is_a?(String)
          # try to split on commas to convert into array
          value.split(',')
        end
      else
        value
    end
  end
end