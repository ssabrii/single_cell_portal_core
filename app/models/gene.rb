class Gene
  include Mongoid::Document

  belongs_to :study
  belongs_to :study_file
  has_many :data_arrays, as: :linear_data

  field :name, type: String
  field :searchable_name, type: String

  index({ name: 1, study_id: 1, study_file_id: 1 }, { unique: true, background: true})
  index({ searchable_name: 1, study_id: 1 }, { unique: false, background: true })
  index({ study_id: 1 }, { unique: false, background: true })
  index({ study_id: 1, study_file_id: 1} , { unique: false, background: true })

  validates_uniqueness_of :name, scope: [:study_id, :study_file_id]
  validates_presence_of :name

  ##
  # INSTANCE METHODS
  ##

  # concatenate all the necessary data_array objects and construct a hash of cell names => expression values
  def scores
    cells = self.concatenate_data_arrays(self.cell_key, 'cells')
    exp_values = self.concatenate_data_arrays(self.score_key, 'expression')
    Hash[cells.zip(exp_values)]
  end

  # key to retrieve data arrays of cell names for this gene
  def cell_key
    "#{self.name} Cells"
  end

  # key to retrieve data arrays of expression values for this gene
  def score_key
    "#{self.name} Expression"
  end

  # concatenate data arrays of a given name/type in order
  def concatenate_data_arrays(array_name, array_type)
    data_arrays = self.data_arrays.where(name: array_name, array_type: array_type).order(:array_index => 'asc')
    all_values = []
    data_arrays.each do |array|
      all_values += array.values
    end
    all_values
  end

  ##
  # CLASS INSTANCE METHODS
  ##

  # calculate a mean value for a given gene based on merged expression scores hash
  def self.mean(scores, cells)
    values = cells.map {|c| scores[c].to_f}
    values.mean
  end

  # calculate a median value for a given gene based on merged expression scores hash
  def self.median(scores, cells)
    values = cells.map {|c| scores[c].to_f}
    self.array_median(values)
  end

  # calculate median of an array
  def self.array_median(values)
    sorted_values = values.sort
    len = sorted_values.length
    (sorted_values[(len - 1) / 2] + sorted_values[len / 2]) / 2.0
  end

  # calculate the z-score of an array
  def self.array_z_score(values)
    mean = values.mean
    stddev = values.stdev
    if stddev === 0.0
      # if the standard deviation is zero, return NaN for all values (to avoid getting Infinity)
      values.map {Float::NAN}
    else
      values.map {|v| (v - mean) / stddev}
    end
  end

  # calculate a z-score for every entry (subtract the mean, divide by the standard deviation)
  # for a given gene based on merged expression scores hash
  def self.z_score(scores, cells)
    values = cells.map {|c| scores[c].to_f}
    self.array_z_score(values)
  end

  # calculate the robust z-score of an array of values
  def self.array_robust_z_score(values)
    median = self.array_median(values)
    deviations = values.map {|v| (v - median).abs}
    # compute median absolute deviation
    mad = self.array_median(deviations)
    if mad === 0.0
      # if the median absolute deviation is zero, return NaN for all values (to avoid getting Infinity)
      values.map {Float::NAN}
    else
      values.map {|v| (v - median) / mad}
    end
  end

  # calculate a robust z-score for every entry (subtract the median, divide by the median absolute deviation)
  # for a given gene based on merged expression scores hash
  def self.robust_z_score(scores, cells)
    values = cells.map {|c| scores[c].to_f}
    self.array_robust_z_score(values)
  end

  # generate new entries based on existing ExpressionScore objects
  def self.generate_new_entries
    start_time = Time.now
    arrays_created = 0
    records = []
    child_records = []
    count = 0
    total_records = ExpressionScore.count
    ExpressionScore.all.each do |expression_score|
      new_gene = Gene.new(study_id: expression_score.study_id, study_file_id: expression_score.study_file_id,
                             name: expression_score.gene, searchable_name: expression_score.searchable_gene)
      records << new_gene.attributes
      cells = expression_score.scores.keys
      exp_values = expression_score.scores.values
      cells.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        child_records << {name: new_gene.cell_key, cluster_name: new_gene.study_file.name, array_type: 'cells',
                    array_index: index + 1, values: slice, study_id: new_gene.study_id,
                    study_file_id: new_gene.study_file_id, linear_data_id: new_gene.id,
                    linear_data_type: 'Gene'
        }
      end
      exp_values.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        child_records << {name: new_gene.score_key, cluster_name: new_gene.study_file.name, array_type: 'expression',
                    array_index: index + 1, values: slice, study_id: new_gene.study_id,
                    study_file_id: new_gene.study_file_id, linear_data_id: new_gene.id,
                    linear_data_type: 'Gene'
        }
      end

      if records.size >= 1000
        count += records.size
        Rails.logger.info "#{Time.now} processed #{count} of #{total_records} Expression Score records"
        Gene.create(records)
        records = []
      end

      if child_records.size >= 1000
        DataArray.create(child_records)
        arrays_created += child_records.size
        child_records = []
      end
    end
    Gene.create(records)
    DataArray.create(child_records)
    arrays_created += child_records.size
    end_time = Time.now
    seconds_diff = (start_time - end_time).to_i.abs

    hours = seconds_diff / 3600
    seconds_diff -= hours * 3600

    minutes = seconds_diff / 60
    seconds_diff -= minutes * 60

    seconds = seconds_diff
    msg = "Gene migration complete: generated #{self.count} new entries with #{arrays_created} child data_arrays; elapsed time: #{hours} hours, #{minutes} minutes, #{seconds} seconds"
    Rails.logger.info msg
    msg
  end
end