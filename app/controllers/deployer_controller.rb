require 'bundler/setup'
require 'fileutils'
require 'date'
require 'erb'
require 'yaml'
require 'git'
require 'deep_merge'
require 'colorize'
require 'logger'
require 'tty-command'
require 'json'
require 'active_support/core_ext/object/deep_dup'
require_relative '../utilities/deployer_utilities'

class DeployerController
  def initialize
    @current_step = 0
    @clusters_conf = {}
    @envs_requested_to_deploy = []
    @envs_to_deploy = []
  end

  def run
    check_required_params
    prepare_local_environment
    clone_iac_repo
    get_clusters_available
    find_environments_to_deploy
    deploy_environments
  end

  def check_required_params
    _announce_step "check required params..."

    unless ENV.key?('GIT_IAC_REPO')
      puts '[ERROR] GIT_IAC_REPO environment variable is missing!'.red
      exit 1
    end

    unless ENV.key?('GIT_IAC_TOKEN')
      puts '[ERROR] GIT_IAC_TOKEN environment variable is missing!'.red
      exit 1
    end

    # applications list based on a YAML file or with a specific ENV
    unless ENV.key?('DEPLOY_ENVIRONMENTS') || ENV.key?('DEPLOY_CONF_FILE')
      puts '[ERROR] DEPLOY_ENVIRONMENTS or DEPLOY_CONF_FILE environment variable must be set!'.red
      exit 1
    end

    puts 'OK.'
  end

  def prepare_local_environment
    _announce_step "Prepare local environment..."

    ENV['GITHUB_TOKEN'] = ENV['GIT_IAC_TOKEN']

    puts "\n#################################################################".green
    puts "\nWe are reading IAC REPO: #{ENV['GIT_IAC_REPO'].green}"
    if ENV.key?('GIT_IAC_BRANCH')
      puts "ON BRANCH: #{ENV['GIT_IAC_BRANCH'].green}"
    end

    if ENV.key?('DEPLOY_ENVIRONMENTS')
      ENV['DEPLOY_ENVIRONMENTS'].split(',').each do |a|
        @envs_requested_to_deploy.push(a)
      end
    end

    age_keys = []
    if ENV.key?('DEPLOY_AGE_KEYS')
      ENV['DEPLOY_AGE_KEYS'].split(',').each do |key|
        age_keys.push(key)
      end
    end

    if ENV.key?('DEPLOY_CONF_FILE')
      begin
        File.open(ENV['DEPLOY_CONF_FILE'], 'r') do |yaml_file|
          yaml_conf = YAML.safe_load(yaml_file)

          @envs_requested_to_deploy.concat(yaml_conf['deploy_environments']) if yaml_conf['deploy_environments']

          # puts yaml_conf['env_vars']
          yaml_conf['env_vars'].each do |env|
            k, v = env.first
            ENV[k] = v
          end if yaml_conf['env_vars'].is_a? Array

          age_keys.concat(yaml_conf['age_keys']) if yaml_conf['age_keys']
        end
      rescue
        puts "\nDEPLOY_CONF_FILE (#{ENV['DEPLOY_CONF_FILE'].green}) doesn't exist, so I'm exit."
        exit 0
      end
    end

    if age_keys.any?
      File.open('age_keys.txt', 'w') do |file|
        content = ''
        age_keys.each do |k|
          content += "#{k}\n"
        end
        file.write(content)
        # puts Dir.pwd + "/age_keys.txt"
        ENV['SOPS_AGE_KEY_FILE'] = "#{Dir.pwd}/age_keys.txt"
      end
    end

    puts "\nWe'd like to deploy these environments:\n"

    @envs_requested_to_deploy.each do |env|
      name = env.keys[0]
      puts "#{name.green}\n"
      next unless env[name]

      env[name].each do |app|
        puts "  - #{app}\n"
      end
    end

    puts "\n#################################################################".green
    puts 'OK.'
  end

  def clone_iac_repo
    _announce_step "Clone iac-repo..."

    if ENV['DEBUG_SKIP_CLONE_REPO_STEP'] == 'true'
      puts "[DEBUG] Step skipped.".green
      return
    end

    # remove iac-repo folder if exists
    FileUtils.rm_rf('iac-repo')

    Git.clone(
      "https://#{ENV['GIT_IAC_TOKEN']}@#{ENV['GIT_IAC_REPO']}",
      'iac-repo',
      { branch: ENV['GIT_IAC_BRANCH'] }
    )

    _announce_substep "Repo IaC cloned."

    result = Utilities.shell.run!('cd iac-repo && chmod +x scripts/install_dependencies.sh && ./scripts/install_dependencies.sh')
    if result.failed?
      puts "[ERROR][DEPENDENCIES] #{result.err}".red
      exit 1
    end

    _announce_substep "Helm dependencies installed."

    result = Utilities.shell.run!('npm install', chdir: 'iac-repo/applications')
    if result.failed?
      puts "[ERROR][CDK8S-INSTALL] #{result.err}".red
      exit 1
    end

    _announce_substep "NPM packages installed."

    puts 'OK.'
  end

  def get_clusters_available
    _announce_step "Get clusters available in iac-repo..."

    Dir.glob('iac-repo/clusters*.yaml').each do |file|
      File.open(file, 'r') do |yaml_file|
        yaml_conf = YAML.safe_load(yaml_file)
        @clusters_conf.deep_merge!(yaml_conf)
      end
    end

    unless @clusters_conf['clusters']
      puts '[ERROR] No clusters configured in iac-repo/clusters*.yaml files.'.red
      exit 1
    end
    # puts @clusters_conf.to_yaml
    puts 'OK.'
  end

  def find_environments_to_deploy
    _announce_step "Find clusters that contain environments we want to deploy..."

    @clusters_conf['clusters'].each do |cluster|
      # puts "cluster: #{cluster['name']}"
      # puts cluster['environments']
      cluster['environments'].each do |cl_app|
        # puts cl_app
        @envs_requested_to_deploy.each do |env|

          environment_name = env.keys[0]
          next unless environment_name == cl_app['name']
          unless settings = @envs_to_deploy.find{ |x| x['settings']['cluster_name'] == cluster['name'] }&.dig('settings')&.deep_dup
            settings = cluster['settings'].merge(cl_app['settings'])
            settings['cluster_name'] = cluster['name']

            auth_method = Utilities.get_cluster_auth_method(settings)

            settings['auth_data'] = auth_method[:data]
          end
          # add env only if not already exists
          @envs_to_deploy |= [{
            'name'         => cl_app['name'],
            'cluster'      => cluster['name'],
            'applications' => env[environment_name],
            'settings'     => settings
          }]
        end
      end
    end

    if @envs_to_deploy.count == 0
      puts "\nNo environments found to deploy, exit.".green

      puts "\nDONE!\n".blue
      exit 0
    end

    puts "Found #{@envs_to_deploy.count} environments to deploy:".green
    puts @envs_to_deploy.map { |e| "#{e['cluster']}: #{e['name']} #{e['applications']}" }
    puts @envs_to_deploy if ENV['DEBUG'] == 'true'

    puts 'OK.'
  end

  def deploy_environments
    _announce_step "Deploy environments..."
    # each for clusters
    @envs_to_deploy.group_by { |e| e['cluster'] }.each do |cluster, envs|
      # preparing environments for this cluster and set up project id in codebase
      _prepare_cluster_environments(cluster, envs)

      # run cdk8s for current cluster environments
      _build_cluster_environments(cluster, envs)

      # deploy environments on the current cluster
      _deploy_cluster_environments(cluster, envs)
    end
  end

  private

  def _announce_step(text)
    @current_step+=1
    @current_substep = 0
    puts "\nStep #{@current_step}: #{text}".yellow
  end

  def _announce_substep(text)
    @current_substep+=1
    puts "Step #{@current_step}.#{@current_substep}: #{text}"
  end

  def _prepare_cluster_environments(cluster, envs)
    envs.each do |env|
      puts "\nPreparing '#{env['name']}' to be deployed on cluster '#{cluster}'...".green
      puts env if ENV['DEBUG'] == 'true'
      settings = env['settings']
      project_id = ""
      auth_data = settings['auth_data']

      ENV["KUBECONFIG"] = auth_data
      print "Test cluster connection with kubectl... "
      if Utilities.get_cluster_version
        puts 'OK.'.green
      end

      # search environment namespaces
      all_namespaces = []
      namespaces = []
      File.open("iac-repo/applications/environments/#{env['name']}/applications_settings.yaml", 'r+') do |yaml_file|
        yaml_content = YAML.safe_load(yaml_file)
        # puts yaml_content.to_yaml
        yaml_content.each do |app, settings|
          next if yaml_content[app].is_a?(String) || !yaml_content[app].key?('projectId')

          if !env['applications'] || (
              env['applications'] &&
              env['applications'].size > 0 &&
              env['applications'].include?(app)
            )
            namespaces.push(settings['namespace'])
          end
          all_namespaces.push(settings['namespace'])
          # Add projectId to any namespace of the environment if it's empty
          if yaml_content[app]['projectId'].to_s.strip.empty? && project_id
            yaml_content[app]['projectId'] = project_id
          end
        end

        # puts yaml_content.to_yaml
        yaml_file.rewind
        yaml_file.write(yaml_content.to_yaml)
        yaml_file.truncate(yaml_file.pos)
      end

      if namespaces.size > 0
        puts "\nNamespaces found in environment codebase (filtered):".green
        puts namespaces
      else
        puts '[ERROR][NAMESPACES] No namespaces found'.red
        exit 1
      end

      env['namespaces'] = namespaces
      env['all_namespaces'] = all_namespaces
    end
  end

  def _build_cluster_environments(cluster, envs)
    envs_cdk8s = envs.map { |e| e['name'] }.join(',')

    puts "\nRun cdk8s for '#{envs_cdk8s}' on cluster '#{cluster}'...".green
    cluster_version = Utilities.get_cluster_version
    puts "Cluster version: #{cluster_version}".yellow
    result = Utilities.shell.run!(
      'cd iac-repo/applications/ && npm run build',
      env: { K8S_VERSION: cluster_version, ENVIRONMENTS: envs_cdk8s }
    )

    if result.failed?
      if result.err.include?('trouble decrypting file')
        puts '[ERROR][CDK8S] ERROR DECRYPTING SECRET, CHECK AGE KEYS.'.red
      end
      puts "[ERROR][CDK8S] #{result}".red
      puts "command output (stdout):"
      puts result.out.red
      puts "command error (stderr):"
      puts result.err.red
      exit 1
    end

    puts 'OK.'
  end

  def _deploy_cluster_environments(cluster, envs)
    yaml_files = []
    Dir.glob('iac-repo/applications/dist/*.k8s.yaml').each do |file|
      yaml_files.push(file)
    end

    envs.each do |env|
      puts "\nDeploying '#{env['name']}' to cluster '#{cluster}'...".green

      namespace_yaml = "iac-repo/applications/dist/*-namespaces-#{env['name']}.k8s.yaml"
      env_compiled_yamls = yaml_files.select { |f| env['namespaces'].any? { |n| f.include?(n) } }.sort

      if (empty_yamls = env_compiled_yamls.reject { |f| YAML.load_file(f) }).any?
        puts "\nSkipping these files as they are empty:".yellow
        puts empty_yamls
        env_compiled_yamls -= empty_yamls
      end

      puts "\nThese files will be deployed:".yellow
      puts namespace_yaml
      puts env_compiled_yamls

      dry_run = ''
      ENV['DEPLOY_DRY_RUN'] = 'client' if ENV['DEPLOY_DRY_RUN'] == 'true'
      if %w[client server].include?(ENV['DEPLOY_DRY_RUN'])
        puts "\n[Commands will be executed in #{ENV['DEPLOY_DRY_RUN']} dry run mode]".yellow
        dry_run = "--dry-run='#{ENV['DEPLOY_DRY_RUN']}'"
      elsif ENV['DEPLOY_ASK_CONFIRM'] == 'true'
        puts "\nDo you really want to deploy? (Y/N)".yellow
        answer = gets.chomp
        if answer.upcase != 'Y'
          puts 'Deploy stopped.'.red
          exit 1
        end
      end

      puts "\nApplying namespaces...".green
      result = Utilities.shell_to_output.run!("kubectl apply #{dry_run} -f #{namespace_yaml}")

      if result.failed?
        puts "[ERROR] #{result.err}".red
        exit 1
      end

      # kubectl apply for namespaces of this environment by name (ex. *-namespaces-{environment_name}.k8s.yaml)
      env_compiled_yamls.each do |yaml|
        puts "\nAppling #{yaml}...".green
        result = Utilities.shell_to_output.run!("kubectl apply #{dry_run} -f #{yaml}")

        if result.failed?
          puts "[ERROR] #{result.err}".red
          exit 1
        end
      end
      # puts result.out
      puts 'OK.'
    end
  end
end
