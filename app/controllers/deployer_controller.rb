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

class DeployerController
  attr_reader :logger

  @g = nil
  def self.g
    @g
  end

  @clusters_conf = []
  def self.clusters_conf
    @clusters_conf
  end

  @envs_requested_to_deploy = []
  def self.envs_requested_to_deploy
    @envs_requested_to_deploy
  end

  @envs_to_deploy = []
  def self.envs_to_deploy
    @envs_to_deploy
  end

  def step_0
    puts "\nStep 0: check required params...".light_yellow
    if !ENV.has_key?('GIT_IAC_REPO')
      puts "[ERROR] GIT_IAC_REPO environment variable is missing!".red
      exit(1)
    end

    if !ENV.has_key?('GIT_IAC_TOKEN')
      puts "[ERROR] GIT_IAC_TOKEN environment variable is missing!".red
      exit(1)
    end


    # applications list based on a YAML file or with a specific ENV
    if !ENV.has_key?('DEPLOY_ENVIRONMENTS') && !ENV.has_key?('DEPLOY_CONF_FILE')
      puts "[ERROR] DEPLOY_ENVIRONMENTS or DEPLOY_CONF_FILE environment variable must be set!".red
      exit(1)
    end

    puts "OK."

  end

  def step_1
    puts "\nStep 1: Prepare local environment...".light_yellow
    ENV['GITHUB_TOKEN'] = ENV['GIT_IAC_TOKEN']

    puts "\n#################################################################".green
    puts "\nWe are reading IAC REPO: #{ENV['GIT_IAC_REPO'].green}"
    if ENV.has_key?('GIT_IAC_BRANCH')
      puts "ON BRANCH: #{ENV['GIT_IAC_BRANCH'].green}"
    end

    @envs_requested_to_deploy = []

    if ENV.has_key?('DEPLOY_ENVIRONMENTS')
      ENV['DEPLOY_ENVIRONMENTS'].split(',').each do |a|
        @envs_requested_to_deploy.push(a)
      end
    end

    age_keys = []
    if ENV.has_key?('DEPLOY_AGE_KEYS')
      ENV['DEPLOY_AGE_KEYS'].split(',').each do |key|
        age_keys.push(key)
      end
    end

    if ENV.has_key?('DEPLOY_CONF_FILE')
      File.open(ENV['DEPLOY_CONF_FILE'], "r") do |yaml_file|
        yaml_conf = YAML.load(ERB.new(File.read(yaml_file)).result)

        if yaml_conf.has_key?('deploy_environments') && yaml_conf['deploy_environments']
          @envs_requested_to_deploy.concat(yaml_conf['deploy_environments'])
        end
        if yaml_conf.has_key?('env_vars') && yaml_conf['env_vars']
          # puts yaml_conf['env_vars']
          yaml_conf['env_vars'].each do |env|
            k, v = env.first
            ENV[k] = v
          end
        end
        if yaml_conf.has_key?('age_keys') && yaml_conf['age_keys']
          age_keys.concat(yaml_conf['age_keys'])
        end
      end
    end

    if age_keys
      File.open("age_keys.txt","w") do |file|
        content = ""
        age_keys.each do |k|
          content += "#{k}\n"
        end
        file.write(content)
        #puts Dir.pwd + "/age_keys.txt"
        ENV['SOPS_AGE_KEY_FILE'] = Dir.pwd + "/age_keys.txt"
      end
    end

    puts "\nWe'd like to deploy these environments:\n"
    @envs_requested_to_deploy.each do |env|
      name = env.keys[0]
      puts "#{name.green}\n"
      env[name].each do | app|
        puts "  - #{app}\n"
      end
    end

    puts "\n#################################################################".green

    FileUtils.rm_rf("iac-repo")
    puts "OK."
  end

  def step_2
    puts "\nStep 2: Clone iac-repo...".light_yellow
    @g = Git.clone("https://#{ENV['GIT_IAC_TOKEN']}@#{ENV['GIT_IAC_REPO']}", "iac-repo", {branch: ENV['GIT_IAC_BRANCH']})
    shell_to_output.run!("cd iac-repo/applications/ && \
    npm install")
    puts "OK."
  end

  def step_3
    puts "\nStep 3: Get clusters available in iac-repo...".light_yellow

    @clusters_conf = {}

    Dir.glob('iac-repo/clusters*.yaml').each do|f|

      File.open(f, "r") do |yaml_file|
        yaml_conf = YAML.load(ERB.new(File.read(yaml_file)).result)
        @clusters_conf.deep_merge!(yaml_conf)
      end
    end

    if !@clusters_conf['clusters']
      puts "[ERROR] No clusters configured in iac-repo/clusters*.yaml files.".red
      exit(1)
    end
    # puts @clusters_conf.to_yaml
    puts "OK."
  end

  def step_4
    puts "\nStep 4: Find clusters that contain environments we want to deploy...".light_yellow

    @envs_to_deploy = []

    @clusters_conf['clusters'].each do |c|
      #puts "cluster: #{c['name']}"
      # puts c['environments']
      c['environments'].each do |cl_app|
        #puts cl_app
        @envs_requested_to_deploy.each do |env|
          environment_name = env.keys[0]
          if environment_name == cl_app['name']
            settings = c['settings'].merge(cl_app['settings'])
            settings['cluster_name'] = c['name']
            # add env only if not already exists
            @envs_to_deploy |= [{
            "name" => cl_app['name'],
            "cluster" => c['name'],
            "applications" => env[environment_name],
            "settings" => settings,
            "helm_repos" => c['helm_repos']
            }]
          end
        end
      end
    end

    if @envs_to_deploy.count == 0
      puts "\nNo environments found to deploy, exit.".green

      puts "\nDONE!\n".blue
      exit(0)
    end

    puts "Found #{@envs_to_deploy.count} environments to deploy:".green
    puts @envs_to_deploy.map { |e| "#{e['cluster']}: #{e['name']} #{e['applications']}"}
    # puts @envs_to_deploy
  end

  def step_5
    puts "\nStep 5: Deploy environments...".light_yellow

    # each for clusters
    @envs_to_deploy.group_by {|e| e['cluster']}.each do |cluster, envs|

      # preparing environment for this cluster and set up project id in codebase
      envs.each do |env|
        puts "Preparing '#{env['name']}' to cluster '#{cluster}'...".green
        # puts env
        projects = rancher_login(env['settings'])
        project_id = rancher_select_project(env['settings'], projects)
        project_namespaces = rancher_list_ns

        if env['helm_repos']
          puts "\nAdding helm repos dependencies...".green
          env['helm_repos'].each do | helm |
            shell_to_output.run!("helm repo add #{helm['name']} #{helm['url']}")
          end
        end

        # search environment namespaces
        all_namespaces = []
        namespaces = []
        File.open("iac-repo/applications/environments/#{env['name']}/applications_settings.yaml", "r+") do |yaml_file|
          yaml_content = YAML.load(yaml_file.read)
          # puts yaml_content.to_yaml

          yaml_content.each do |app, settings|
            # puts app
            # puts settings['namespace']
            # puts env['applications']

            if !env['applications'] || (
                env['applications'] &&
                env['applications'].size > 0 &&
                env['applications'].include?(app)
              )
              namespaces.push(settings['namespace'])
            end
            all_namespaces.push(settings['namespace'])
            # mandatory to add projectId to any namespace of the environment
            yaml_content[app]['projectId'] = project_id
          end

          yaml_file.rewind
          yaml_file.write(yaml_content.to_yaml)
          yaml_file.truncate(yaml_file.pos)
        end

        puts "\nNamespaces found in environment codebase (filtered):".green
        puts namespaces


        puts "\nCreate any environment namespaces on project #{project_id}...".green
        all_namespaces.each do |namespace|
          # if we are using rancher, we have to create namespaces with rancher cli, otherwise
          # credentials limited to a specific project (no cluster scope roles) cannot create namespaces with yaml
          print "Check namespace '#{namespace}' existance... "
          found_namespace = project_namespaces.detect {|p| p['NAME'] == namespace}
          if !found_namespace
            result = shell_to_output.run!("rancher namespaces create #{namespace}")
            if result.failed?
              puts "[ERROR][RANCHER-NS] #{result.err}".red
              exit(1)
            end
            puts "Namespace created.".green
          else
            puts "OK.".green
          end
        end

        env['namespaces'] = namespaces
        env['all_namespaces'] = all_namespaces
      end

      puts "\nRun cdk8s...".green
      cluster_version = rancher_get_cluster_version
      puts "Cluster version: #{cluster_version}".yellow
      result = shell.run!("cd iac-repo/applications/ && \
      npm run build", env: {K8S_VERSION: cluster_version})

      if result.failed?
        if result.err.include?('trouble decrypting file')
          puts "[ERROR][CDK8S] ERROR DECRYPTING SECRET, CHECK AGE KEYS.".light_red
        end
        puts "[ERROR][CDK8S] #{result.err}".red
        exit(1)
      end
      puts "OK."

      yaml_files = []
      Dir.glob("iac-repo/applications/dist/*.k8s.yaml").each do|f|
        yaml_files.push(f)
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

        dryrun = ""
        if ["true", "client", "server"].include?(ENV['DEPLOY_DRY_RUN'])

          if ENV['DEPLOY_DRY_RUN'] == "true"
            ENV['DEPLOY_DRY_RUN'] = "client"
          end
          puts "\n[Commands will be executed in #{ENV['DEPLOY_DRY_RUN']} dry run mode]".yellow
          dryrun = "--dry-run='#{ENV['DEPLOY_DRY_RUN']}'"
        elsif ENV['DEPLOY_ASK_CONFIRM'] == "true"
          puts "\nDo you really want to deploy? (Y/N)".light_yellow
          answer = gets.chomp
          if answer.upcase != 'Y'
            puts "Deploy stopped.".red
            exit(1)
          end
        end

        puts "\nApplying namespaces...".green
        result = shell_to_output.run!("rancher kubectl apply #{dryrun} -f \
        #{namespace_yaml}")

        if result.failed?
          puts "[ERROR][RANCHER] #{result.err}".red
          exit(1)
        end

        # kubectl apply for namespaces of this environment by name (ex. *-namespaces-{environment_name}.k8s.yaml)
        env_compiled_yamls.each do |yaml|
          puts "\nAppling #{yaml}...".green
          result = shell_to_output.run!("rancher kubectl apply #{dryrun} -f \
          #{yaml}")

          if result.failed?
            puts "[ERROR][RANCHER] #{result.err}".red
            exit(1)
          end
        end
        #puts result.out
        puts "OK."

      end
    end
  end

  def shell
    @_cmd ||= TTY::Command.new(printer: :null)
  end

  def shell_to_output
    @_cmd_output ||= TTY::Command.new(printer: :quiet)
  end

  def analyze_ascii_table(header)
    spaces_count = 0
    char_count = 0
    columns_length = []
    header.each_char.with_index do |c, i|
      if c == ' '
        spaces_count += 1
      elsif spaces_count >= 2
        columns_length.push(char_count)
        char_count = 0
        spaces_count = 0
      end
      char_count += 1
    end

    return columns_length
  end

  def get_line_ascii_table(columns_length, line, header)
    row = header ? {} : []
    columns_length.each_with_index do |i, index|
      column, part2 = line.slice!(0...i), line
      if header
        row[header[index]] = column.strip!
      else
        row.push(column.strip!)
      end
    end

    if header
      row[header[header.length-1]] = line.strip!
    else
      row.push(line.strip!)
    end

    return row
  end

  def ascii_table_to_array(ascii_table)
    table = []
    header = ascii_table.lines[0]
    ascii_table_struct = analyze_ascii_table(header)
    #puts header
    header_line = get_line_ascii_table(ascii_table_struct, header, nil)

    ascii_table.each_line.with_index do |line, index|
      next if index == 0
      converted_line = get_line_ascii_table(ascii_table_struct, line, header_line)
      if converted_line["NUMBER"] || converted_line["ID"]
        table.push(converted_line)
      end
    end

    return table
  end

  def rancher_login(settings)
    result = shell.run!("echo '1' | rancher login #{settings['rancher_url']} -t #{settings['rancher_access_key']}:#{settings['rancher_secret_key']}")

    if result.failed?
      puts "[ERROR][RANCHER-LOGIN] #{result.err}".red
      exit(1)
    end

    if result.out.include?("CLUSTER NAME")
      puts "LOGGED IN TO #{settings["rancher_url"]}."

      projects = ascii_table_to_array(result.out)
    end

    return projects
  end

  def rancher_select_project(settings, projects)
    puts "Try to select Project '#{settings["rancher_project"]}' on cluster '#{settings["cluster_name"] }'...".green

    found_project = projects.detect {|p| p['CLUSTER NAME'] == settings["cluster_name"] && p['PROJECT NAME'] == settings["rancher_project"]}

    if !found_project
      puts "[WARN] Project '#{settings["rancher_project"]}' doesn't exist on cluster '#{settings["cluster_name"] }'. Trying to create it...".yellow
      default_project = projects.detect {|p| p['CLUSTER NAME'] == settings["cluster_name"] && p['PROJECT NAME'] == "Default"}
      if !default_project
        puts "[ERROR] Project \"Default\" doesn't exist on cluster '#{settings["cluster_name"]}' or cluster '#{settings["cluster_name"]}' doesn't exist.".red
        exit(1)
      end

      result = shell.run!("rancher context switch #{default_project['PROJECT ID']}")
      if result.failed?
        puts "[ERROR][RANCHER-CONTEXT] #{result.err}".red
        exit(1)
      end

      result = shell.run!("rancher projects create --cluster #{settings["cluster_name"]} #{settings["rancher_project"]}")
      if result.failed?
        puts "[ERROR][RANCHER-PROJECT] #{result.err}".red
        exit(1)
      end

      puts "Project '#{settings["rancher_project"]}' created on cluster '#{settings["cluster_name"] }'.".green

      # refresh projects and found_project
      result = shell.run!("echo '\n' | rancher context switch")
      if result.failed?
        puts "[ERROR][RANCHER-CONTEXT] #{result.err}".red
        exit(1)
      end
      projects = ascii_table_to_array(result.out)
      found_project = projects.detect {|p| p['CLUSTER NAME'] == settings["cluster_name"] && p['PROJECT NAME'] == settings["rancher_project"]}
      if !found_project
        puts "[ERR] Project '#{settings["rancher_project"]}' doesn't exist on cluster '#{settings["cluster_name"] }' also after create it.".red
        exit(1)
      end
    end

    result = shell.run!("rancher context switch #{found_project['PROJECT ID']}")
    if result.failed?
      puts "[ERROR][RANCHER-CONTEXT] #{result.err}".red
      exit(1)
    end

    puts "PROJECT SELECTED."
    return found_project['PROJECT ID']
  end

  def rancher_list_ns
    result = shell.run!("rancher namespaces")

    if result.failed?
      puts "[ERROR][RANCHER-NS] #{result.err}".red
      exit(1)
    end

    namespaces = ascii_table_to_array(result.out)
    return namespaces
  end

  def rancher_get_cluster_version
    result = shell.run!("rancher kubectl version --output=json")

    if result.failed?
      puts "[ERROR][RANCHER] #{result.err}".red
      exit(1)
    end

    server_version = JSON.load(result.out)['serverVersion']
    return server_version['major'] + "." + server_version['minor']
  end




end
