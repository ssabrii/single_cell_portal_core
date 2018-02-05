class CreateGenesAndCellMetadata < Mongoid::Migration
  def self.up
    ClusterGroup.delay.generate_new_data_arrays
    Gene.delay.generate_new_entries
    CellMetadatum.delay.generate_new_entries
  end

  def self.down
    Gene.delete_all
    CellMetadatum.delete_all
    DataArray.where(:linear_data_type.in => %w(Gene CellMetadatum ClusterGroup Study)).delete_all
  end
end