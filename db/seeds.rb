# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
#   Mayor.create(name: 'Emanuel', city: cities.first)

study = Study.create!(name: 'Testing Study', description: '<p>This is the test study.</p>', data_dir: 'none')
expression_file = StudyFile.create!(name: 'expression_matrix.txt', upload_file_name: 'expression_matrix.txt', study_id: study.id, file_type: 'Expression Matrix', y_axis_label: 'Expression Scores')
cluster_file = StudyFile.create!(name: 'Test Cluster', upload_file_name: 'coordinates.txt', study_id: study.id, file_type: 'Cluster', x_axis_label: 'X', y_axis_label: 'Y', z_axis_label: 'Z')

cluster = ClusterGroup.create!(name: 'Test Cluster', study_id: study.id, study_file_id: cluster_file.id, cluster_type: '3d', cell_annotations: [
    {
        name: 'Category',
        type: 'group',
        values: %w(a b c d)
    },
    {
        name: 'Intensity',
        type: 'numeric',
        values: []
    }
])
# create raw arrays of values to use in DataArrays and StudyMetadatum
category_array = ['a', 'b', 'c', 'd'].repeated_combination(18).to_a.flatten
metadata_label_array = ['E', 'F', 'G', 'H'].repeated_combination(18).to_a.flatten
point_array = 0.upto(category_array.size - 1).to_a
cluster_cell_array = point_array.map {|p| "cell_#{p}"}
all_cell_array = 0.upto(metadata_label_array.size - 1).map {|c| "cell_#{c}"}
intensity_array = point_array.map {|p| rand}
metadata_score_array = all_cell_array.map {|p| rand}
study_cells = study.data_arrays.build(name: 'All Cells', array_type: 'cells', cluster_name: 'Testing Study', array_index: 1,
                                      values: all_cell_array)
study_cells.save!
x_array = cluster.data_arrays.build(name: 'x', cluster_name: cluster.name, array_type: 'coordinates', array_index: 1,
                                    study_id: study.id, values: point_array)
x_array.save!
y_array = cluster.data_arrays.build(name: 'y', cluster_name: cluster.name, array_type: 'coordinates', array_index: 1,
                                    study_id: study.id, values: point_array)
y_array.save!
z_array = cluster.data_arrays.build(name: 'z', cluster_name: cluster.name, array_type: 'coordinates', array_index: 1,
                                    study_id: study.id, values: point_array)
z_array.save!
cluster_txt = cluster.data_arrays.build(name: 'text', cluster_name: cluster.name, array_type: 'cells', array_index: 1,
                                    study_id: study.id, values: cluster_cell_array)
cluster_txt.save!
cluster_cat_array = cluster.data_arrays.build(name: 'Category', cluster_name: cluster.name, array_type: 'annotations', array_index: 1,
                                    study_id: study.id, values: category_array)
cluster_cat_array.save!
cluster_int_array = cluster.data_arrays.build(name: 'Intensity', cluster_name: cluster.name, array_type: 'annotations', array_index: 1,
                                    study_id: study.id, values: intensity_array)
cluster_int_array.save!
cell_metadata_1 = CellMetadatum.create!(name: 'Label', annotation_type: 'group', study_id: study.id, values: metadata_label_array.uniq)
cell_metadata_2 = CellMetadatum.create!(name: 'Score', annotation_type: 'numeric', study_id: study.id, values: metadata_score_array.uniq)
meta1_vals = cell_metadata_1.data_arrays.build(name: 'Label', cluster_name: 'Label', array_type: 'annotations', array_index: 1,
                                               values: metadata_label_array)
meta1_vals.save!
meta2_vals = cell_metadata_2.data_arrays.build(name: 'Score', cluster_name: 'Score', array_type: 'annotations', array_index: 1,
                                               values: metadata_score_array)
meta2_vals.save!
gene_1 = Gene.create!(name: 'Gene_1', searchable_name: 'gene_1', study_id: study.id, study_file_id: expression_file.id)
gene_2 = Gene.create!(name: 'Gene_2', searchable_name: 'gene_2', study_id: study.id, study_file_id: expression_file.id)
gene1_vals = gene_1.data_arrays.build(name: gene_1.score_key, array_type: 'expression', cluster_name: expression_file.name,
                                      array_index: 1, study_file_id: expression_file.id, values: metadata_score_array)
gene1_vals.save!
gene1_cells = gene_1.data_arrays.build(name: gene_1.cell_key, array_type: 'cells', cluster_name: expression_file.name,
                                      array_index: 1, study_file_id: expression_file.id, values: all_cell_array)
gene1_cells.save!
gene2_vals = gene_2.data_arrays.build(name: gene_2.score_key, array_type: 'expression', cluster_name: expression_file.name,
                                      array_index: 1, study_file_id: expression_file.id, values: metadata_score_array)
gene2_vals.save!
gene2_cells = gene_2.data_arrays.build(name: gene_2.cell_key, array_type: 'cells', cluster_name: expression_file.name,
                                       array_index: 1, study_file_id: expression_file.id, values: all_cell_array)
gene2_cells.save!
User.create!(email:'fake@fake.gov', password:'password')