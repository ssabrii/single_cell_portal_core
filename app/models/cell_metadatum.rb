class CellMetadatum
  include Mongoid::Document

  belongs_to :study
  belongs_to :study_file
  has_many :data_arrays, as: :linear_data

  field :name, type: String
  field :annotation_type, type: String
  field :values, type: Array

  index({ name: 1, annotation_type: 1, study_id: 1 }, { unique: false, background: true })
  index({ study_id: 1 }, { unique: false, background: true })
  index({ study_id: 1, study_file_id: 1 }, { unique: false, background: true })

  validates_uniqueness_of :name, scope: [:study_id, :annotation_type]
  validates_presence_of :name, :annotation_type

  ##
  # INSTANCE METHODS
  ##

  # concatenate all the necessary data_array objects and construct a hash of cell names => expression values
  def cell_annotations
    cells = self.study.all_cells_array
    annot_values = self.concatenate_data_arrays(self.name, 'annotations')
    Hash[cells.zip(annot_values)]
  end

  # concatenate data arrays of a given name/type in order
  def concatenate_data_arrays(array_name, array_type)
    data_arrays = DataArray.where(name: array_name, array_type: array_type).order(:array_index => 'asc')
    all_values = []
    data_arrays.each do |array|
      all_values += array.values
    end
    all_values
  end

  ##
  #
  # CLASS INSTANCE METHODS
  #
  ##

  # generate new entries based on existing StudyMetadata objects
  def self.generate_new_entries
    start_time = Time.now
    arrays_created = 0
    # we only want to generate the list of 'All Cells' once per study, so do that first
    Study.all.each do |study|
      all_cells = study.all_cells
      all_cells.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        cell_array = study.data_arrays.build(study_file_id: study.metadata_file.id, name: 'All Cells',
                                             cluster_name: study.metadata_file.name, array_type: 'cells',
                                             array_index: index + 1, values: slice, study_id: study.id)
        cell_array.save
      end
    end
    records = []
    StudyMetadatum.all.each do |study_metadatum|
      cell_metadatum = CellMetadatum.create(study_id: study_metadatum.study_id, study_file_id: study_metadatum.study_file_id,
                                            name: study_metadatum.name, annotation_type: study_metadatum.annotation_type,
                                            values: study_metadatum.values)
      annot_values = study_metadatum.cell_annotations.values
      annot_values.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        records << {name: study_metadatum.name, cluster_name: cell_metadatum.study_file.name, array_type: 'annotations',
                    array_index: index + 1, values: slice, study_id: cell_metadatum.study_id,
                    study_file_id: cell_metadatum.study_file_id, linear_data_id: cell_metadatum.id,
                    linear_data_type: 'CellMetadatum'
        }
      end
      if records.size >= 1000
        DataArray.create(records)
        arrays_created += records.size
        records = []
      end
    end
    DataArray.create(records)
    arrays_created += records.size
    end_time = Time.now
    seconds_diff = (start_time - end_time).to_i.abs

    hours = seconds_diff / 3600
    seconds_diff -= hours * 3600

    minutes = seconds_diff / 60
    seconds_diff -= minutes * 60

    seconds = seconds_diff
    msg = "Cell Metadata migration complete: generated #{self.count} new entries with #{arrays_created} child data_arrays; elapsed time: #{hours} hours, #{minutes} minutes, #{seconds} seconds"
    Rails.logger.info msg
    msg
  end
end