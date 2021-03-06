# encoding: utf-8
# author: Christoph Hartmann
# author: Dominik Richter

require 'thor'
require 'erb'

module Compliance
  class ComplianceCLI < Inspec::BaseCLI # rubocop:disable Metrics/ClassLength
    namespace 'compliance'

    # TODO: find another solution, once https://github.com/erikhuda/thor/issues/261 is fixed
    def self.banner(command, _namespace = nil, _subcommand = false)
      "#{basename} #{subcommand_prefix} #{command.usage}"
    end

    def self.subcommand_prefix
      namespace
    end

    desc "login SERVER --insecure --user='USER' --token='TOKEN'", 'Log in to a Chef Compliance SERVER'
    option :insecure, aliases: :k, type: :boolean,
      desc: 'Explicitly allows InSpec to perform "insecure" SSL connections and transfers'
    option :user, type: :string, required: false,
      desc: 'Chef Compliance Username'
    option :password, type: :string, required: false,
      desc: 'Chef Compliance Password'
    option :apipath, type: :string, default: '/api',
      desc: 'Set the path to the API, defaults to /api'
    option :token, type: :string, required: false,
      desc: 'Chef Compliance access token'
    option :refresh_token, type: :string, required: false,
      desc: 'Chef Compliance refresh token'
    def login(server) # rubocop:disable Metrics/AbcSize
      # show warning if the Compliance Server does not support

      options['server'] = server
      url = options['server'] + options['apipath']

      if !options['user'].nil? && !options['password'].nil?
        # username / password
        _success, msg = login_username_password(url, options['user'], options['password'], options['insecure'])
      elsif !options['user'].nil? && !options['token'].nil?
        # access token
        _success, msg = store_access_token(url, options['user'], options['token'], options['insecure'])
      elsif !options['refresh_token'].nil? && !options['user'].nil?
        # refresh token
        _success, msg = store_refresh_token(url, options['refresh_token'], true, options['user'], options['insecure'])
        # TODO: we should login with the refreshtoken here
      elsif !options['refresh_token'].nil?
        _success, msg = login_refreshtoken(url, options)
      else
        puts 'Please run `inspec compliance login SERVER` with options --token or --refresh_token, --user, and --insecure or --not-insecure'
        exit 1
      end

      puts '', msg
    end

    desc "login_automate SERVER --user='USER' --ent='ENT' --dctoken or --usertoken='TOKEN'", 'Log in to an Automate SERVER'
    option :dctoken, type: :string,
      desc: 'Data Collector token'
    option :usertoken, type: :string,
      desc: 'Automate user token'
    option :user, type: :string,
      desc: 'Automate username'
    option :ent, type: :string,
      desc: 'Enterprise for Chef Automate reporting'
    option :insecure, aliases: :k, type: :boolean,
      desc: 'Explicitly allows InSpec to perform "insecure" SSL connections and transfers'
    def login_automate(server) # rubocop:disable Metrics/AbcSize
      options['server'] = server
      url = options['server'] + '/compliance/profiles'

      if url && !options['user'].nil? && !options['ent'].nil?
        if !options['dctoken'].nil? || !options['usertoken'].nil?
          msg = login_automate_config(url, options['user'], options['dctoken'], options['usertoken'], options['ent'], options['insecure'])
        else
          puts "Please specify a token using --dctoken='DATA_COLLECTOR_TOKEN' or usertoken='AUTOMATE_TOKEN' "
          exit 1
        end
      else
        puts "Please login to your automate instance using 'inspec compliance login_automate SERVER --user AUTOMATE_USER --ent AUTOMATE_ENT --dctoken DC_TOKEN or --usertoken USER_TOKEN' "
        exit 1
      end
      puts '', msg
    end

    desc 'profiles', 'list all available profiles in Chef Compliance'
    def profiles
      config = Compliance::Configuration.new
      return if !loggedin(config)

      msg, profiles = Compliance::API.profiles(config)
      if !profiles.empty?
        # iterate over profiles
        headline('Available profiles:')
        profiles.each { |profile|
          li("#{profile[:org]}/#{profile[:name]}")
        }
      else
        puts msg, 'Could not find any profiles'
        exit 1
      end
    end

    desc 'exec PROFILE', 'executes a Chef Compliance profile'
    exec_options
    def exec(*tests)
      config = Compliance::Configuration.new
      return if !loggedin(config)
      # iterate over tests and add compliance scheme
      tests = tests.map { |t| 'compliance://' + t }
      # execute profile from inspec exec implementation
      diagnose
      run_tests(tests, opts)
    end

    desc 'upload PATH', 'uploads a local profile to Chef Compliance'
    option :overwrite, type: :boolean, default: false,
      desc: 'Overwrite existing profile on Chef Compliance.'
    def upload(path) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, PerceivedComplexity, Metrics/CyclomaticComplexity
      config = Compliance::Configuration.new
      return if !loggedin(config)

      unless File.exist?(path)
        puts "Directory #{path} does not exist."
        exit 1
      end

      vendor_deps(path, options) if File.directory?(path)

      o = options.dup
      configure_logger(o)
      # check the profile, we only allow to upload valid profiles
      profile = Inspec::Profile.for_target(path, o)

      # start verification process
      error_count = 0
      error = lambda { |msg|
        error_count += 1
        puts msg
      }

      result = profile.check
      unless result[:summary][:valid]
        error.call('Profile check failed. Please fix the profile before upload.')
      else
        puts('Profile is valid')
      end

      # determine user information
      if config['token'].nil? || config['user'].nil?
        error.call('Please login via `inspec compliance login`')
      end

      # owner
      owner = config['user']
      # read profile name from inspec.yml
      profile_name = profile.params[:name]

      # check that the profile is not uploaded already,
      # confirm upload to the user (overwrite with --force)
      if Compliance::API.exist?(config, "#{owner}/#{profile_name}") && !options['overwrite']
        error.call('Profile exists on the server, use --overwrite')
      end

      # abort if we found an error
      if error_count > 0
        puts "Found #{error_count} error(s)"
        exit 1
      end

      # if it is a directory, tar it to tmp directory
      if File.directory?(path)
        archive_path = Dir::Tmpname.create([profile_name, '.tar.gz']) {}
        puts "Generate temporary profile archive at #{archive_path}"
        profile.archive({ output: archive_path, ignore_errors: false, overwrite: true })
      else
        archive_path = path
      end

      puts "Start upload to #{owner}/#{profile_name}"
      pname = ERB::Util.url_encode(profile_name)

      config['server_type'] == 'automate' ? upload_msg = 'Uploading to Chef Automate' : upload_msg = 'Uploading to Chef Compliance'
      puts upload_msg
      success, msg = Compliance::API.upload(config, owner, pname, archive_path)

      if success
        puts 'Successfully uploaded profile'
      else
        puts 'Error during profile upload:'
        puts msg
        exit 1
      end
    end

    desc 'version', 'displays the version of the Chef Compliance server'
    def version
      config = Compliance::Configuration.new
      if config['server_type'] == 'automate'
        puts 'Version not available when logged in with Automate.'
      else
        info = Compliance::API.version(config['server'], config['insecure'])
        if !info.nil? && info['version']
          puts "Chef Compliance version: #{info['version']}"
        else
          puts 'Could not determine server version.'
          exit 1
        end
      end
    end

    desc 'logout', 'user logout from Chef Compliance'
    def logout
      config = Compliance::Configuration.new
      unless config.supported?(:oidc) || config['token'].nil? || config['server_type'] == 'automate'
        config = Compliance::Configuration.new
        url = "#{config['server']}/logout"
        Compliance::API.post(url, config['token'], config['insecure'], !config.supported?(:oidc))
      end
      success = config.destroy

      if success
        puts 'Successfully logged out'
      else
        puts 'Could not log out'
      end
    end

    private

    def login_automate_config(url, user, dctoken, usertoken, ent, insecure) # rubocop:disable Metrics/ParameterLists
      config = Compliance::Configuration.new
      config['user'] = user
      config['server'] = url
      config['automate'] = {}
      config['automate']['ent'] = ent
      config['server_type'] = 'automate'
      config['insecure'] = insecure

      # determine token method being used
      if !dctoken.nil?
        config['token'] = dctoken
        token_type = 'dctoken'
        token_msg = 'data collector token'
      else
        config['token'] = usertoken
        token_type = 'usertoken'
        token_msg = 'automate user token'
      end

      config['automate']['token_type'] = token_type
      config.store
      msg = "Stored configuration for Chef Automate: '#{url}' with user: '#{user}', ent: '#{ent}' and your #{token_msg}"
      msg
    end

    def login_refreshtoken(url, options)
      success, msg, access_token = Compliance::API.get_token_via_refresh_token(url, options['refresh_token'], options['insecure'])
      if success
        config = Compliance::Configuration.new
        config['server'] = url
        config['token'] = access_token
        config['insecure'] = options['insecure']
        config['version'] = Compliance::API.version(url, options['insecure'])
        config['server_type'] = 'compliance'
        config.store
      end

      [success, msg]
    end

    def login_username_password(url, username, password, insecure)
      config = Compliance::Configuration.new
      success, msg, api_token = Compliance::API.get_token_via_password(url, username, password, insecure)
      if success
        config['server'] = url
        config['user'] = username
        config['token'] = api_token
        config['insecure'] = insecure
        config['version'] = Compliance::API.version(url, insecure)
        config['server_type'] = 'compliance'
        config.store
        success = true
      end
      [success, msg]
    end

    # saves a user access token (limited time)
    def store_access_token(url, user, token, insecure)
      config = Compliance::Configuration.new
      config['server'] = url
      config['insecure'] = insecure
      config['user'] = user
      config['token'] = token
      config['version'] = Compliance::API.version(url, insecure)
      config.store

      [true, 'API access token stored']
    end

    # saves a refresh token supplied by the user
    def store_refresh_token(url, refresh_token, verify, user, insecure)
      config = Compliance::Configuration.new
      config['server'] = url
      config['refresh_token'] = refresh_token
      config['user'] = user
      config['insecure'] = insecure
      config['version'] = Compliance::API.version(url, insecure)

      if !verify
        config.store
        success = true
        msg = 'API refresh token stored'
      else
        success, msg, access_token = Compliance::API.get_token_via_refresh_token(url, refresh_token, insecure)
        if success
          config['token'] = access_token
          config.store
          msg = 'API access token verified and stored'
        end
      end

      [success, msg]
    end

    def loggedin(config)
      serverknown = !config['server'].nil?
      puts 'You need to login first with `inspec compliance login` or `inspec compliance login_automate`' if !serverknown
      serverknown
    end
  end

  # register the subcommand to Inspec CLI registry
  Inspec::Plugins::CLI.add_subcommand(ComplianceCLI, 'compliance', 'compliance SUBCOMMAND ...', 'Chef Compliance commands', {})
end
