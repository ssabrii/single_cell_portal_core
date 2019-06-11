function renderMorpheusDotPlot(dataPath, annotPath, selectedAnnot, selectedAnnotType, target, annotations, fitType, dotHeight) {
  console.log('render status of ' + target + ' at start: ' + $(target).data('rendered'));
  $(target).empty();

  // Collapse by median
  var tools = [{
    name: 'Collapse',
    params: {
      shape: 'circle',
      collapse: ['Columns'],
      collapse_to_fields: [selectedAnnot],
      compute_percent: true,
      pass_expression: '>',
      pass_value: '0',
      percentile: '100'
    }
  }];

  var config = {
    shape: 'circle',
    dataset: dataPath,
    el: $(target),
    menu: null,
    colorScheme: {
      scalingMode: 'relative'
    },
    tools: tools
  };

  // Set height if specified, otherwise use default setting of 500 px
  if (dotHeight !== undefined) {
    config.height = dotHeight;
  } else {
    config.height = 500;
  }

  // Fit rows, columns, or both to screen
  if (fitType === 'cols') {
    config.columnSize = 'fit';
  } else if (fitType === 'rows') {
    config.rowSize = 'fit';
  } else if (fitType === 'both') {
    config.columnSize = 'fit';
    config.rowSize = 'fit';
  } else {
    config.columnSize = null;
    config.rowSize = null;
  }

  // Load annotations if specified
  if (annotPath !== '') {
    config.columnAnnotations = [{
      file : annotPath,
      datasetField : 'id',
      fileField : 'NAME',
      include: [selectedAnnot]
    }];
    config.columnSortBy = [
      {field: selectedAnnot, order:0}
    ];
    config.columns = [
      {field: selectedAnnot, display: 'text'}
    ];
    config.rows = [
      {field: 'id', display: 'text'}
    ];

    // Create mapping of selected annotations to colorBrewer colors
    var annotColorModel = {};
    annotColorModel[selectedAnnot] = {};
    var sortedAnnots = annotations['values'].sort();

    // Calling % 27 will always return to the beginning of colorBrewerSet once we use all 27 values
    $(sortedAnnots).each(function(index, annot) {
      annotColorModel[selectedAnnot][annot] = colorBrewerSet[index % 27];
    });
    config.columnColorModel = annotColorModel;
  }

  config.colorScheme = {
    values : [0, 0.5, 1],
    colors : ['blue', 'purple', 'red']
  };

  // Instantiate heatmap and embed in DOM element
  var dotPlot = new morpheus.HeatMap(config);
  dotPlot.tabManager.setOptions({autohideTabBar:true});
  $(target).off();
  $(target).on('heatMapLoaded', function (e, heatMap) {
    var tabItems = dotPlot.tabManager.getTabItems();
    dotPlot.tabManager.setActiveTab(tabItems[1].id);
    dotPlot.tabManager.remove(tabItems[0].id);
  });

  // Set render variable to true for tests
  $(target).data('morpheus', dotPlot);
  $(target).data('rendered', true);
  console.log('render status of ' + target + ' at end: ' + $(target).data('rendered'));
}

function drawDotplot(height) {
  $(window).off('resizeEnd');

  // Clear out previous stored dotplot object
  $('#dot-plot').data('dotplot', null);

  // If height isn't specified, pull from stored value, defaults to 500
  if (height === undefined) {
    height = $('#dot-plot').data('height');
  }

  // Pull fit type as well, defaults to ''
  var fit = $('#dot-plot').data('fit');

  var dotplotRowCentering = $('#dotplot_row_centering').val();
  var selectedAnnot = $('#annotation').val();
  var annotName = selectedAnnot.split('--')[0];
  var annotType = selectedAnnot.split('--')[1];
  dataPath = dotPlotDataPathBase + '&row_centered=' + dotplotRowCentering;
  var cluster = $('#cluster').val();
  $('#search_cluster').val(cluster);
  $('#search_annotation').val(''); // clear value first
  $('#search_annotation').val(selectedAnnot);

  dataPath += '&cluster=' + cluster + '&request_user_token=' + dotPlotRequestToken;
  var newAnnotPath = dotPlotAnnotPathBase + '?cluster=' + cluster + '&annotation=' + selectedAnnot + '&request_user_token=' + requestToken;
  var colorScalingMode = 'relative';
  // Determine whether to scale row colors globally or by row
  if (dotplotRowCentering !== '') {
    colorScalingMode = 'fixed';
  }
  var consensus = dotPlotConsensus;
  console.log(consensus);
  // // Log action of rendering Morpheus
  // var logUrl = '<%= javascript_safe_url(expression_query_path(study_name: params[:study_name], search: {genes: @dotplot_gene_list })) %>';
  // logUrl += '--cluster=' + cluster + '--annotation=' + annotName;
  // $.ajax({
  //     url: '<%= log_action_path %>?url_string=' + logUrl,
  //     dataType: 'script'
  // });

  var renderUrlParams = getRenderUrlParams();
  // Get annotation values to set color values in Morpheus and draw dotplot in callback
  $.ajax({
    url: dotPlotAnnotValuesPath + '?' + renderUrlParams,
    dataType: 'JSON',
    success: function(annotations) {
      renderMorpheusDotPlot(dataPath, newAnnotPath, annotName, annotType, '#dot-plot', annotations, fit, height);
    }
  });
}

$('#dotplot_row_centering, #annotation').change(function() {
  $('#dot-plot').data('rendered', false);
  if ($(this).attr('id') === 'annotation') {
    var an = $(this).val();
    // Keep track for search purposes
    $('#search_annotation').val(an);
    $('#gene_set_annotation').val(an);
  }
  drawDotplot();
});

// When changing cluster, re-render annotation options and call render function
$('#cluster').change(function(){
  $('#dot-plot').data('rendered', false);

  var newCluster = $(this).val();
  // Keep track for search purposes
  $('#search_cluster').val(newCluster);
  $('#gene_set_cluster').val(newCluster);
  var currAnnot = $('#annotation').val();
  // Get new annotation options and re-render
  $.ajax({
    url: dotPlotNewAnnotsPath + '?cluster=' + newCluster,
    method: 'GET',
    dataType: 'script',
    success: function (data) {
      // Parse response as a string and see if currently selected annotation exists in new annotations
      if (data.indexOf(currAnnot) >= 0) {
        $('#annotation').val(currAnnot);
      }
      $(document).ready(function () {
        // Since we now have new annotations, we need to set them in the search form for persistence
        var an = $('#annotation').val();
        $('#search_annotation').val(an);
        $('#gene_set_annotation').val(an);
        drawDotplot();
      });
    }
  });
});

$('#resize-dotplot').click(function() {
  $('#dot-plot').data('rendered', false);

  var newHeight = parseInt($('#dotplot_size').val());
  $('#dot-plot').data('height', newHeight);
  console.log('resizing dotplot to ' + newHeight);
  drawDotplot(newHeight);
});

$('.fit-btn').click(function() {
  $('#dot-plot').data('rendered', false);

  var btn = $(this);
  var btnState = btn.data('active');
  var newState = btnState === 'on' ? 'off' : 'on';
  btn.data('active', newState);
  var fitType = btn.data('fit');
  console.log('setting fit type: ' + fitType + 'to ' + newState);

  btn.toggleClass('active');
  currFit = plot.data('fit');
  // Determine state and set appropriately
  if (newState === 'on') {
    if (currFit !== '' && fitType !== currFit) {
      fitType = 'both'
    }
  } else {
    if (currFit === 'both') {
      fitType = fitType === 'rows' ? 'cols' : 'rows';
    } else {
      fitType = '';
    }
  }

  $('#dot-plot').data('fit', fitType);
  drawDotplot();
});