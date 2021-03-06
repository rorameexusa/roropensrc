require 'uri'

##
# Intended to be used by the AccountController to handle omniauth logins
module Concerns::OmniauthLogin
  def self.included(base)
    # disable CSRF protection since that should be covered by the omniauth strategy
    base.skip_before_filter :verify_authenticity_token, :only => [:omniauth_login]
  end

  def omniauth_login
    auth_hash = request.env['omniauth.auth']

    return render_400 unless auth_hash.valid?

    # Set back url to page the omniauth login link was clicked on
    params[:back_url] = request.env['omniauth.origin']
    user = User.find_or_initialize_by_identity_url identity_url_from_omniauth(auth_hash)

    decision = OpenProject::OmniAuth::Authorization.authorized? auth_hash
    if decision.approve?
      authorization_successful user, auth_hash
    else
      authorization_failed user, decision.message
    end
  end

  def omniauth_failure
    logger.warn(params[:message]) if params[:message]
    show_error I18n.t(:error_external_authentication_failed)
  end

  def self.direct_login?
    direct_login_provider.is_a? String
  end

  ##
  # Per default the user may choose the usual password login as well as several omniauth providers
  # on the login page and in the login drop down menu.
  #
  # With his configuration option you can set a specific omniauth provider to be
  # used for direct login. Meaning that the login provider selection is skipped and
  # the configured provider is used directly instead.
  #
  # If this option is active /login will lead directly to the configured omniauth provider
  # and so will a click on 'Sign in' (as opposed to opening the drop down menu).
  def self.direct_login_provider
    OpenProject::Configuration['omniauth_direct_login_provider']
  end

  def self.direct_login_provider_url(params = {})
    url_with_params "/auth/#{direct_login_provider}", params if direct_login?
  end

  private

  def authorization_successful(user, auth_hash)
    if user.new_record?
      create_user_from_omniauth user, auth_hash
    else
      if user.active?
        user.log_successful_login
        OpenProject::OmniAuth::Authorization.after_login! user, auth_hash
      end
      login_user_if_active(user)
    end
  end

  def authorization_failed(user, error)
    logger.warn "Authorization for User #{user.id} failed: #{error}"
    show_error error
  end

  def show_error(error)
    flash[:error] = error
    redirect_to :action => 'login'
  end

  # a user may login via omniauth and (if that user does not exist
  # in our database) will be created using this method.
  def create_user_from_omniauth(user, auth_hash)
    # Self-registration off
    return self_registration_disabled unless Setting.self_registration?

    fill_user_fields_from_omniauth user, auth_hash

    opts = { after_login: ->(u) { OpenProject::OmniAuth::Authorization.after_login! u, auth_hash } }

    # Create on the fly
    register_user_according_to_setting(user, opts) do
      # Allow registration form to show provider-specific title
      @omniauth_strategy = auth_hash[:provider]

      # Store a timestamp so we can later make sure that authentication information can
      # only be reused for a short time.
      session_info = auth_hash.merge(omniauth: true, timestamp: Time.new)

      onthefly_creation_failed(user, session_info)
    end
  end

  def register_via_omniauth(user, session, permitted_params)
    auth = session[:auth_source_registration]
    return if handle_omniauth_registration_expired(auth)

    fill_user_fields_from_omniauth(user, auth)
    user.update_attributes(permitted_params.user_register_via_omniauth)

    opts = { after_login: ->(u) { OpenProject::OmniAuth::Authorization.after_login! u, auth } }
    register_user_according_to_setting user, opts
  end

  def fill_user_fields_from_omniauth(user, auth)
    user.update_attributes omniauth_hash_to_user_attributes(auth)
    user.register
    user
  end

  def omniauth_hash_to_user_attributes(auth)
    info = auth[:info]
    {
      login:        info[:email],
      mail:         info[:email],
      firstname:    info[:first_name] || info[:name],
      lastname:     info[:last_name],
      identity_url: identity_url_from_omniauth(auth)
    }
  end

  def identity_url_from_omniauth(auth)
    "#{auth[:provider]}:#{auth[:uid]}"
  end

  # if the omni auth registration happened too long ago,
  # we don't accept it anymore.
  def handle_omniauth_registration_expired(auth)
    if auth['timestamp'] < Time.now - 30.minutes
      flash[:error] = I18n.t(:error_omniauth_registration_timed_out)
      redirect_to(signin_url)
    end
  end

  def self.url_with_params(url, params = {})
    URI.parse(url).tap do |uri|
      query = URI.decode_www_form(uri.query || '')
      params.each do |key, value|
        query << [key, value]
      end
      uri.query = URI.encode_www_form(query) unless query.empty?
    end.to_s
  end
end
