##
#
# HCAMetadatum: Module that all HCA-style metadata objects inherit from.  Contains general getters/setters
# for loading and parsing source metadata schema objects
#
##

module HCAUtilities
  # root directory for storing metadata schema copies
  #
  # * *return*
  #   - +Pathname+ => path to root directory containing JSON files of same version number
  def get_definition_root
    Rails.root.join('data', 'HCA_metadata', self.version)
  end

  # remote endpoint containing metadata schema
  #
  # * *return*
  #   - +String+ => url to remote schema definition JSON in github
  def get_definition_url(filename: self.filename)
    "https://raw.githubusercontent.com/HumanCellAtlas/metadata-schema/#{self.version}/json_schema/#{filename}"
  end

  # local filesytem location of copy of JSON schema
  #
  # * *return*
  #   - +Pathname+ => path to metadata schema JSON file
  def get_definition_filepath(filename: self.filename)
    Rails.root.join(self.get_definition_root, filename)
  end

  # return a parsed JSON object detailing the metadata schema for the requested object
  #
  #   - +filename+ (String) => (optional) name of metadata file to parse, defaults to object's filename
  #
  # * *return*
  #   - +Hash+ => Hash of metadata schema values, or error message
  def parse_definition_schema(filename: self.filename)
    begin
      # check for local copy first
      if File.exists?(self.get_definition_filepath(filename: filename))
        existing_schema = File.read(self.get_definition_filepath(filename: filename))
        JSON.parse(existing_schema)
      else
        Rails.logger.info "#{Time.now}: saving new local copy of #{self.get_definition_filepath(filename: filename)}"
        metadata_schema = RestClient.get self.get_definition_url(filename: filename)
        # write a local copy
        unless Dir.exist?(self.get_definition_root)
          FileUtils.mkdir_p(self.get_definition_root)
        end
        new_schema = File.new(self.get_definition_filepath(filename: filename), 'w+')
        new_schema.write metadata_schema.body
        new_schema.close
        JSON.parse(metadata_schema.body)
      end
    rescue RestClient::ExceptionWithResponse => e
      Rails.logger.error "#{Time.now}: Error retrieving remote HCA #{filename} metadata schema: #{e.message}"
      {error: "Error retrieving definition schema: #{e.message}"}
    rescue JSON::ParserError => e
      Rails.logger.error "#{Time.now}: Error parsing HCA #{filename} metadata schema: #{e.message}"
      {error: "Error parsing definition schema: #{e.message}"}
    end
  end

  # retrieve property definition information
  # can retrieve info such as require fields, field definitions, property list, etc.
  #
  # * *params*
  #   - +key+ (String) => root-level key to retrieve from metadata object (e.g. properties, required, etc.)
  #   - +field+ (String) => (optional) sub-level key to retrieve from metadata object
  #
  # * *return*
  #   - +Hash+ => Hash of object definitions
  def parse_definitions(key:, field: nil)
    begin
      defs = self.parse_definition_schema[key]
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

  # retrieve nested field definition information
  # can retrieve info such as require fields, field definitions, property list, etc.
  #
  # * *params*
  #   - +reference_url+ (String) => reference URL to pull source schema from
  #   - +lookup+ (String) => lookup field
  #
  # * *return*
  #   - +Hash+ => Hash of object definitions
  def get_nested_definitions(reference_url:, lookup:)
    begin
      if reference_url.include?('#')
        parts = reference_url.split('#')
        entity = parts.last.split('/').last
        defs = parse_definitions(key: 'definitions', field: entity)
        defs[lookup]
      else
        filename = reference_url.split('/').last
        ext_schema = parse_definition_schema(filename: filename)
        ext_schema[lookup]
      end
    rescue NoMethodError => e
      Rails.logger.error "#{Time.now}: Error accessing #{reference_url} field definitions for #{lookup}: #{e.message}"
      nil
    end
  end

  # set a value based on the schema definition for a particular field
  #
  # * *params*
  #   - +definitions+ (Hash) => Hash of field defintions (from *parse_definitions*)
  #   - +value+ (Multiple) => value to set
  #
  # * *return*
  #   - +Multiple+ => Can return String, Integer, Array
  #
  # * *raises*
  #   - +TypeError+ => if value to be set does not match the expected type or pattern (if present)
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
        array_item_type = value_items['type']
        if value.is_a?(Array)
          if array_item_type.present?
            validation_class = array_item_type.classify.constantize
            value.each do |val|
              if !val.is_a?(validation_class)
                raise TypeError.new("#{val} is not a #{validation_class}; type mismatch of #{val.class.name}")
              end
            end
          end
        else
          raise TypeError.new("#{value} is not the expected intput type; expected array but found #{value.class.name}.")
        end
        value
      else
        value
    end
  end

  # validate the schema of an item in a payload based on its definitions
  #
  # * *params*
  #   - +entity+ (Hash) => entity to source definitions & requirements from (e.g. project, sample, contact, etc.)
  #   - +version+ (String) => schema version number of this metadata object
  #   - +item+ (Hash) => item to be validated
  #
  # * *return*
  #   - +Hash+ => validated Hash of input item, extraneous values will be removed
  #
  # * *raises*
  #   - +ArgumentError+ => if input item does not contain a required field
  def validate_item_payload(entity_definitions, required_fields, item_payload)
    entity_definitions.each do |field, definitions|
      # get corresponding value from item
      item_value = item_payload[field]
      # check if field is required
      if required_fields.include?(field) && item_value.blank?
        raise ArgumentError.new("Missing required property in payload: #{field}")
      end
      if definitions['items'].present? && definitions['items']['$ref'].present?
        # we have an external reference to validate
        external_ref = definitions['items']['$ref']
        req = self.get_nested_definitions(reference_url: external_ref, lookup: 'required')
        defs = self.get_nested_definitions(reference_url: external_ref, lookup: 'properties')
        if item_value.is_a?(Array)
          item_value.each do |val|
            validate_item_payload(defs, req, val)
          end
        else
          validate_item_payload(defs, req, item_value)
        end
      else
        item_payload[field] = set_value_by_type(definitions, item_value)
      end
    end
    item_payload
  end
end