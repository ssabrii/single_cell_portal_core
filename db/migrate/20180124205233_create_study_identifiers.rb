class CreateStudyIdentifiers < Mongoid::Migration
  def self.up
    Study.order_by(:created_at => 'asc').each do |study|
      StudyIdentifier.create(study_id: study.id)
    end
  end

  def self.down
    StudyIdentifier.delete_all
  end
end