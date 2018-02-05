class GeneController < ApplicationController

  ###
  #
  # This controller is only used for the autocomplete funcitonality in the gene search panel
  #
  ###

  before_action :set_gene, only: [:show]
  autocomplete :gene, :name

  def index
    @genes = Gene.all
  end

  def show
  end

  def get_autocomplete_items(parameters)
    all_genes = mongoid_get_autocomplete_items(parameters)
    genes = all_genes.where(:study_id => params[:study_id]).to_a.uniq{|e| e.name}
    genes
  end

  private

  def set_gene
    @gene = Gene.find(params[:id])
  end
end

