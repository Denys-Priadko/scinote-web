class AssetsController < ApplicationController
  include WopiUtil
  # include ActionView::Helpers
  include ActionView::Helpers::AssetTagHelper
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::UrlHelper
  include ActionView::Context
  include ApplicationHelper
  include InputSanitizeHelper
  include FileIconsHelper

  before_action :load_vars, except: :create_wopi_file
  before_action :check_read_permission
  before_action :check_edit_permission, only: :edit

  def file_preview
    response_json = {
      'id' => @asset.id,
      'type' => (@asset.image? ? 'image' : 'file'),

      'filename' => truncate(escape_input(@asset.file_name),
                             length: Constants::FILENAME_TRUNCATION_LENGTH),
      'download-url' => download_asset_path(@asset, timestamp: Time.now.to_i)
    }

    can_edit = if @assoc.class == Step
                 can_manage_protocol_in_module?(@protocol) || can_manage_protocol_in_repository?(@protocol)
               elsif @assoc.class == Result
                 can_manage_module?(@my_module)
               elsif @assoc.class == RepositoryCell
                 can_manage_repository_rows?(@repository.team)
               end

    if @asset.image?
      if ['image/jpeg', 'image/pjpeg'].include? @asset.file.content_type
        response_json['quality'] = @asset.file_image_quality || 90
      end
      response_json.merge!(
        'editable' =>  @asset.editable_image? && can_edit,
        'mime-type' => @asset.file.content_type,
        'large-preview-url' => @asset.large_preview
      )
    else
      response_json['preview-icon'] = render_to_string(partial: 'shared/file_preview_icon.html.erb',
                                                       locals: { asset: @asset })
    end

    if wopi_enabled? && wopi_file?(@asset)
      edit_supported, title = wopi_file_edit_button_status
      response_json['wopi-controls'] = render_to_string(
        partial: 'assets/wopi/file_wopi_controls.html.erb',
        locals: {
          asset: @asset,
          can_edit: can_edit,
          edit_supported: edit_supported,
          title: title
        }
      )
    end
    respond_to do |format|
      format.json do
        render json: response_json
      end
    end
  end

  # Check whether the wopi file can be edited and return appropriate response
  def wopi_file_edit_button_status
    file_ext = @asset.file_name.split('.').last
    if Constants::WOPI_EDITABLE_FORMATS.include?(file_ext)
      edit_supported = true
      title = ''
    else
      edit_supported = false
      title = if Constants::FILE_TEXT_FORMATS.include?(file_ext)
                I18n.t('assets.wopi_supported_text_formats_title')
              elsif Constants::FILE_TABLE_FORMATS.include?(file_ext)
                I18n.t('assets.wopi_supported_table_formats_title')
              else
                I18n.t('assets.wopi_supported_presentation_formats_title')
              end
    end
    return edit_supported, title
  end

  def download
    if !@asset.file.attached?
      render_404
    else
      redirect_to rails_blob_path(@asset.file, disposition: 'attachment')
    end
  end

  def edit
    action = @asset.file_size.zero? && !@asset.locked? ? 'editnew' : 'edit'
    @action_url = append_wd_params(@asset.get_action_url(current_user, action, false))
    @favicon_url = @asset.favicon_url('edit')
    tkn = current_user.get_wopi_token
    @token = tkn.token
    @ttl = (tkn.ttl * 1000).to_s
    @asset.step&.protocol&.update(updated_at: Time.now)

    create_wopi_file_activity(current_user, true)

    render layout: false
  end

  def view
    @action_url = append_wd_params(@asset.get_action_url(current_user, 'view', false))
    @favicon_url = @asset.favicon_url('view')
    tkn = current_user.get_wopi_token
    @token = tkn.token
    @ttl = (tkn.ttl * 1000).to_s

    render layout: false
  end

  def update_image
    @asset = Asset.find(params[:id])
    orig_file_size = @asset.file_size
    orig_file_name = @asset.file_name
    return render_403 unless can_read_team?(@asset.team)

    @asset.file.attach(io: params.require(:image), filename: orig_file_name)
    @asset.save!
    # release previous image space
    @asset.team.release_space(orig_file_size)
    # Post process file here
    @asset.post_process_file(@asset.team)
    @asset.step&.protocol&.update(updated_at: Time.now)

    render_html = if @asset.step
                    asset_position = @asset.step.asset_position(@asset)
                    render_to_string(
                      partial: 'steps/attachments/item.html.erb',
                      locals: {
                        asset: @asset,
                        i: asset_position[:pos],
                        assets_count: asset_position[:count],
                        step: @asset.step
                      },
                      formats: :html
                    )
                  else
                    render_to_string(
                      partial: 'shared/asset_link',
                      locals: { asset: @asset, display_image_tag: true },
                      formats: :html
                    )
                  end

    respond_to do |format|
      format.json do
        render json: { html: render_html }
      end
    end
  end

  # POST: create_wopi_file_path
  def create_wopi_file
    # Presence validation
    params.require(%i(element_type element_id file_type))

    # File type validation
    render_403 && return unless %w(docx xlsx pptx).include?(params[:file_type])

    # Asset validation
    asset = Asset.new(created_by: current_user)
    asset.file.attach(io: StringIO.new,
                      filename: "#{params[:file_name]}.#{params[:file_type]}",
                      content_type: wopi_content_type(params[:file_type]))

    unless asset.valid?(:wopi_file_creation)
      render json: {
        message: asset.errors
      }, status: 400 and return
    end

    # Create file depending on the type
    if params[:element_type] == 'Step'
      step = Step.find(params[:element_id].to_i)
      render_403 && return unless can_manage_protocol_in_module?(step.protocol) ||
                                  can_manage_protocol_in_repository?(step.protocol)
      step_asset = StepAsset.create!(step: step, asset: asset)
      step.protocol&.update(updated_at: Time.now)

      edit_url = edit_asset_url(step_asset.asset_id)
    elsif params[:element_type] == 'Result'
      my_module = MyModule.find(params[:element_id].to_i)
      render_403 and return unless can_manage_module?(my_module)

      # First create result and then the asset
      result = Result.create(name: file.original_filename,
                             my_module: my_module,
                             user: current_user)
      result_asset = ResultAsset.create!(result: result, asset: asset)

      edit_url = edit_asset_url(result_asset.asset_id)
    else
      render_404 and return
    end

    # Return edit url
    render json: {
      success: true,
      edit_url: edit_url
    }, status: :ok
  end

  private

  def load_vars
    @asset = Asset.find_by_id(params[:id])
    return render_404 unless @asset

    @assoc ||= @asset.step
    @assoc ||= @asset.result
    @assoc ||= @asset.repository_cell

    if @assoc.class == Step
      @protocol = @asset.step.protocol
    elsif @assoc.class == Result
      @my_module = @assoc.my_module
    elsif @assoc.class == RepositoryCell
      @repository = @assoc.repository_column.repository
    end
  end

  def check_read_permission
    if @assoc.class == Step
      render_403 && return unless can_read_protocol_in_module?(@protocol) ||
                                  can_read_protocol_in_repository?(@protocol)
    elsif @assoc.class == Result
      render_403 and return unless can_read_experiment?(@my_module.experiment)
    elsif @assoc.class == RepositoryCell
      render_403 and return unless can_read_team?(@repository.team)
    end
  end

  def check_edit_permission
    if @assoc.class == Step
      render_403 && return unless can_manage_protocol_in_module?(@protocol) ||
                                  can_manage_protocol_in_repository?(@protocol)
    elsif @assoc.class == Result
      render_403 and return unless can_manage_module?(@my_module)
    elsif @assoc.class == RepositoryCell
      render_403 and return unless can_manage_repository_rows?(@repository.team)
    end
  end

  def append_wd_params(url)
    exclude_params = %w(wdPreviousSession wdPreviousCorrelation)
    wd_params = params.as_json.select { |key, _value| key[/^wd.*/] && !(exclude_params.include? key) }.to_query
    url + '&' + wd_params
  end

  def asset_params
    params.permit(:file)
  end

  def asset_data_type(asset)
    return 'wopi' if wopi_file?(asset)
    return 'image' if asset.image?

    'file'
  end
end
