module Utilities
  extend self

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

    columns_length
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

    row
  end

  def ascii_table_to_array(ascii_table)
    table = []
    header = ascii_table.lines[0]
    ascii_table_struct = analyze_ascii_table(header)
    # puts header
    header_line = get_line_ascii_table(ascii_table_struct, header, nil)

    ascii_table.each_line.with_index do |line, index|
      next if index == 0

      converted_line = get_line_ascii_table(ascii_table_struct, line, header_line)
      if converted_line['NUMBER'] || converted_line['ID']
        table.push(converted_line)
      end
    end

    table
  end

  def get_cluster_auth_method(settings)
    puts "Get cluster '#{settings['cluster_name']}' auth method..."
    if (settings.key?('secret') && !settings['secret'].empty?)
      puts "Found a secret, trying to decode it..."
      result = shell.run!("sops -d ./iac-repo/#{settings['secret']}")
      if result.failed?
        puts "[ERROR][CLUSTER-AUTH] #{result.err}".red
        exit 1
      end
      yaml_content = YAML.safe_load(result.out)
      if yaml_content["data"]["KUBE_CONFIG"]
        puts "Found a kubeconfig in the secret, saving it... "
        FileUtils.mkdir_p("iac-repo/clusters/kubeconfig")
        path = "iac-repo/clusters/kubeconfig/#{yaml_content["name"]}.yaml"
        File.open("#{path}", 'w') do |file|
          file.write(yaml_content["data"]["KUBE_CONFIG"])
        end
        return { auth_mode: "KUBECTL", data: path }
      end
      if yaml_content["data"]["IAM_USER"]
        print "Found a iam_user, trying to get a kubeconfig... "
        shell.run!("aws configure --profile #{yaml_content["name"]} set aws_access_key_id #{yaml_content["data"]["IAM_USER"]["AWS_ACCESS_KEY_ID"]}")
        shell.run!("aws configure --profile #{yaml_content["name"]} set aws_secret_access_key #{yaml_content["data"]["IAM_USER"]["AWS_SECRET_ACCESS_KEY"]}")
        shell.run!("aws configure --profile #{yaml_content["name"]} set region #{yaml_content["data"]["IAM_USER"]["AWS_DEFAULT_REGION"]}")
        path = "iac-repo/clusters/kubeconfig/#{yaml_content["name"]}.yaml"
        # By passing the PROFILE, we don't need to pass it elsewhere as we pass the kubecontext which
        # has the correct profile.
        result = shell.run!("AWS_PROFILE=#{yaml_content["name"]} aws eks update-kubeconfig \
                            --name #{yaml_content['name']} \
                            --alias #{yaml_content['name']} \
                            --kubeconfig #{path}")
        if result.failed?
          puts "[ERROR][GET-AUTH] #{result.err}".red
          exit 1
        end
        puts 'OK.'.green
        return { auth_mode: "KUBECTL", data: path }
      end
      if yaml_content["data"]["RANCHER"]
        puts "Found a rancher setup in the secret, we'll using it."
        return { auth_mode: "RANCHER", data: yaml_content["data"]["RANCHER"] }
      end
    end
    puts "[WARNING][GET-AUTH] Using plain rancher credentials instead of a secret is deprecated, please update your configuration.".yellow
    return { auth_mode: "RANCHER", data: "" }
  end

  def get_cluster_version(auth_mode)
    result = shell.run!("kubectl version --output=json")

    if result.failed?
      puts "[ERROR][#{auth_mode}] #{result.err}".red
      exit 1
    end

    server_version = JSON.parse(result.out)['serverVersion']

    "#{server_version['major']}.#{server_version['minor'].gsub(/[^\d*]/, '')}"
  end

  def rancher_login(settings)
    result = shell.run!("echo '1' | rancher login #{settings['rancher_url']} -t #{settings['rancher_access_key']}:#{settings['rancher_secret_key']}")

    if result.failed?
      puts "[ERROR][RANCHER-LOGIN] #{result.err}".red
      exit 1
    end

    if result.out.include?('CLUSTER NAME')
      puts "LOGGED IN TO #{settings['rancher_url']}."

      projects = ascii_table_to_array(result.out)
    end

    projects
  end

  def rancher_select_project(settings, projects)
    puts "Try to select Project '#{settings['rancher_project']}' on cluster '#{settings['cluster_name']}'...".green

    found_project = projects.detect do |project|
      project['CLUSTER NAME'] == settings['cluster_name'] && project['PROJECT NAME'] == settings['rancher_project']
    end

    unless found_project
      puts "[WARN] Project '#{settings['rancher_project']}' doesn't exist on cluster '#{settings['cluster_name'] }'. Trying to create it...".yellow
      default_project = projects.detect do |project|
        project['CLUSTER NAME'] == settings['cluster_name'] && project['PROJECT NAME'] == 'Default'
      end
      unless default_project
        puts "[ERROR] Project \"Default\" doesn't exist on cluster '#{settings['cluster_name']}' or cluster '#{settings['cluster_name']}' doesn't exist.".red
        exit 1
      end

      result = shell.run!("rancher context switch #{default_project['PROJECT ID']}")
      if result.failed?
        puts "[ERROR][RANCHER-CONTEXT] #{result.err}".red
        exit 1
      end

      result = shell.run!("rancher projects create --cluster #{settings['cluster_name']} #{settings['rancher_project']}")
      if result.failed?
        puts "[ERROR][RANCHER-PROJECT] #{result.err}".red
        exit 1
      end

      puts "Project '#{settings['rancher_project']}' created on cluster '#{settings['cluster_name']}'.".green

      # refresh projects and found_project
      result = shell.run!("echo '\n' | rancher context switch")
      if result.failed?
        puts "[ERROR][RANCHER-CONTEXT] #{result.err}".red
        exit 1
      end
      projects = ascii_table_to_array(result.out)
      found_project = projects.detect do |project|
        project['CLUSTER NAME'] == settings['cluster_name'] && project['PROJECT NAME'] == settings['rancher_project']
      end
      unless found_project
        puts "[ERR] Project '#{settings['rancher_project']}' doesn't exist on cluster '#{settings['cluster_name']}' also after create it.".red
        exit 1
      end
    end

    result = shell.run!("rancher context switch #{found_project['PROJECT ID']}")
    if result.failed?
      puts "[ERROR][RANCHER-CONTEXT] #{result.err}".red
      exit 1
    end

    puts 'PROJECT SELECTED.'

    found_project['PROJECT ID']
  end

  def rancher_list_ns
    result = shell.run!('rancher namespaces')
    # puts result
    if result.failed?
      puts "[ERROR][RANCHER-NS] #{result.err}".red
      exit 1
    end

    ascii_table_to_array(result.out)
  end

end
