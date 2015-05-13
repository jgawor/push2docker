require "fileutils"
require "find"
require "json"
require "open-uri"
require "shellwords"
require "timeout"
require "uri"
require "yaml"
require 'startup_script_generator.rb'

module Push2Docker

  module_function

  def run(app_name, app_path, buildpack_url, cache_dir, output_dir)
    @app_name = app_name
    @compile_id = rand(2**64).to_s(36) # because UUIDs need a gem

    tmp_dir = '/tmp'
    stage_dir = "#{tmp_dir}/staged"
    build_dir = "#{stage_dir}/app"

    # ensure cache_dir exists
    FileUtils.mkdir_p(cache_dir)

    FileUtils.mkdir_p(build_dir)

    if File.exist?(app_path)
      if File.file?(app_path)
        system "unzip -q #{app_path} -d #{build_dir}"
      else
        FileUtils.cp_r("#{app_path}/.", "#{build_dir}")
      end
    else
      fail("wrong app")
    end

    # get buildpack
    if File.directory?(buildpack_url)
      buildpack_dir = buildpack_url
    else
      buildpack_dir = fetch_buildpack(buildpack_url)
    end

    # detect
    buildpack_name = detect(build_dir, buildpack_dir)

    # compile
    compile(build_dir, buildpack_dir, cache_dir)
    
    # tmp - read before release
    process_types = parse_procfile(build_dir)

    # release
    metadata = release(build_dir, buildpack_dir)
    release_data = YAML.load(metadata)
    
    if !process_types['web'].nil?
      start_command = process_types['web']
    elsif !release_data['default_process_types']['web'].nil?
      start_command = release_data['default_process_types']['web']
    end
    
    puts "Start command: #{start_command}"

    prune(build_dir)

    create_startup_script(stage_dir, start_command)
    create_dockerfile(stage_dir, '$PWD/.start.sh')
    system "cd #{stage_dir} && docker build --no-cache=true -t #{app_name} ."
    if $?.exitstatus != 0
      raise("Error creating Docker image")
    else
      puts "Docker image successfully created with '#{app_name}' tag."
    end
    
  ensure
    if !buildpack_dir.nil? && !File.directory?(buildpack_url)
      FileUtils.rm_rf(buildpack_dir)
    end
  end

  def fetch_buildpack(buildpack_url)
    buildpack_dir = "/tmp/buildpack_#{@compile_id}"

    Timeout.timeout((ENV["BUILDPACK_FETCH_TIMEOUT"] || 60 * 5).to_i) do
      FileUtils.mkdir_p(buildpack_dir)
      if buildpack_url =~ /^https?:\/\/.*\.(tgz|tar\.gz)($|\?)/
        print("-----> Fetching buildpack... ")
        IO.popen("tar xz -C #{buildpack_dir}", "w") do |tar|
          IO.copy_stream(open(buildpack_url), tar)
        end
      else
        print("-----> Cloning buildpack... ")
        url, sha = buildpack_url.split("#")
        clear_var("GIT_DIR") do
          system("git", "clone", Shellwords.escape(url), buildpack_dir,
                 [:out, :err] => "/dev/null") # or raise("Couldn't clone")
          system("git", "checkout", Shellwords.escape(treeish),
                 [:out, :err] => "/dev/null", :chdir => buildpack_dir) if sha
        end
      end
    end

    FileUtils.chmod_R(0755, File.join(buildpack_dir, "bin"))
    puts("done")

    buildpack_dir
  rescue StandardError, Timeout::Error => e
    FileUtils.rm_rf(buildpack_dir)
    raise("Error fetching buildpack: " + e.message)
  end

  def detect(build_dir, buildpack_dir)
    name = `#{File.join(buildpack_dir, "bin", "detect")} #{build_dir}`.strip
    if $?.exitstatus != 0
      raise("No compatible app detected")
    else
      puts("-----> #{name} app detected")
    end
    return name
  end

  def compile(build_dir, buildpack_dir, cache_dir)
    bin_compile = File.join(buildpack_dir, 'bin', 'compile')
    timeout = (ENV["COMPILE_TIMEOUT"] || 900).to_i
    Timeout.timeout(timeout) do
      pid = spawn({}, bin_compile, build_dir, cache_dir,
                  unsetenv_others: false, err: :out)
      Process.wait(pid)
      raise("Compile failed") unless $?.exitstatus.zero?
    end
  rescue Timeout::Error
    raise("Compile failed: timed out; must complete in #{timeout} seconds")
  end

  def release(build_dir, buildpack_dir)
    output = `#{File.join(buildpack_dir, "bin", "release")} #{build_dir}`.strip
    if $?.exitstatus != 0
      raise("Release failed")
    else
      puts("-----> #{output}")
      return output
    end
  end

  def prune(build_dir)
    FileUtils.rm_rf(File.join(build_dir, ".git"))
    FileUtils.rm_rf(File.join(build_dir, "tmp"))

    Find.find(build_dir) do |path|
      File.delete(path) if File.basename(path) == ".DS_Store"
    end
  end

  def parse_procfile(build_dir)
    path = File.join(build_dir, "Procfile")
    return {} unless File.exists?(path)

    process_types = File.read(path).split("\n").inject({}) do |ps, line|
      if m = line.match(/^([a-zA-Z0-9_]+):?\s+(.*)/)
        ps[m[1]] = m[2]
      end
      ps
    end

    process_types
  end

  def create_startup_script(stage_dir, start_command)
    generator = StartupScriptGenerator.new(start_command, "", "")
    start_file = File.new(File.join(stage_dir, '.start.sh'), 'w')
    start_file.puts(generator.generate)
    start_file.close
    File.chmod(0755, start_file)
  end

  def create_dockerfile(stage_dir, start_command)
    docker_file = File.new(File.join(stage_dir, 'Dockerfile'), 'w')
    docker_file.puts("FROM cloudfoundry/#{cf_stack}")
    docker_file.puts('RUN useradd -m vcap')
    docker_file.puts("COPY . /home/vcap")
    docker_file.puts('RUN chown -R vcap:vcap /home/vcap')
    docker_file.puts('ENV HOME /home/vcap/app')
    docker_file.puts('ENV TMPDIR /home/vcap/tmp')
    docker_file.puts("ENV VCAP_APPLICATION \'#{vcap_application}\'")
    docker_file.puts("ENV VCAP_APP_HOST #{VCAP_APP_HOST}")
    docker_file.puts("ENV VCAP_APP_PORT #{VCAP_APP_PORT}")
    docker_file.puts("ENV PORT #{VCAP_APP_PORT}")
    docker_file.puts('EXPOSE $PORT')
    docker_file.puts('USER vcap')
    docker_file.puts('WORKDIR /home/vcap')
    docker_file.puts("CMD #{start_command}")
    docker_file.close
  end

  def vcap_application
    vcap_app = {}
    vcap_app['host'] = VCAP_APP_HOST
    vcap_app['port'] = VCAP_APP_PORT
    vcap_app['name'] = vcap_app['application_name'] = @app_name
    vcap_app['application_id'] = '0'
    vcap_app['instance_index'] = 0
    vcap_app.to_json
  end

  VCAP_APP_PORT = "8080".freeze
  VCAP_APP_HOST = "0.0.0.0".freeze

  def cf_stack
    ENV['CF_STACK'] || 'lucid64'
  end

  # utils

  def clear_var(k)
    v = ENV.delete(k)
    begin
      yield
    ensure
      ENV[k] = v
    end
  end

end
