# frozen_string_literal: true

require 'bounty-targets/bugcrowd'
require 'bounty-targets/hackerone'
require 'erb'
require 'fileutils'
require 'tmpdir'
require 'uri'

module BountyTargets
  class CLI
    def run!
      timestamp = Time.now
      root = File.expand_path(File.join(__dir__, '..', '..'))

      with_ssh_keys do |git_ssh_cmd|
        Dir.mktmpdir do |tmpdir|
          Dir.chdir(tmpdir) do
            # Clone + setup
            `GIT_SSH_COMMAND=#{git_ssh_cmd} git clone git@github.com:arkadiyt/bounty-targets-data.git .`
            `git config user.name 'bounty-targets'`
            `git config user.email '<>'`

            # Fetch all hackerone/bugcrowd data
            scan!(File.join(Dir.pwd, 'data'))

            break if `git status --porcelain`.empty?

            # Generate README file
            erb = ERB.new(IO.read(File.join(root, 'config', 'README.md.erb')))
            readme = erb.result_with_hash(timestamp: timestamp.strftime('%A %m/%d/%Y %R (UTC)'))
            IO.write('README.md', readme)

            # Commit + push
            commits = IO.readlines(File.join(root, 'config', 'commits.txt'))
            commit_message = commits.sample(2).map(&:strip).map(&:capitalize).join(' ') +
              ' (' + timestamp.strftime('%m-%d-%Y %R') + ')'
            `git add .`
            `git commit -m '#{commit_message}'`
            `GIT_SSH_COMMAND=#{git_ssh_cmd} git push origin master`
          end
        end
      end
    end

    def scan!(output_dir)
      FileUtils.mkdir_p(output_dir)

      hackerone = BountyTargets::Hackerone.new
      hackerone_data = hackerone.scan
      IO.write(File.join(output_dir, 'hackerone_data.json'), ::JSON.pretty_generate(hackerone_data))
      schema = hackerone.schema
      IO.write(File.join(output_dir, 'hackerone_schema.graphql'), schema.to_definition)

      bugcrowd = BountyTargets::Bugcrowd.new
      bugcrowd_data = bugcrowd.scan
      IO.write(File.join(output_dir, 'bugcrowd_data.json'), ::JSON.pretty_generate(bugcrowd_data))

      # Sanity check for changes in page markup, network issues, etc
      hackerone_uris = hackerone.uris
      bugcrowd_uris = bugcrowd.uris
      if hackerone_uris.all?(&:empty?) || bugcrowd_uris.all?(&:empty?)
        raise StandardError, "Missing uris (#{hackerone_uris.length} hackerone, #{bugcrowd_uris.length} bugcrowd)"
      end

      domains, wildcards = parse_all_uris(hackerone_uris + bugcrowd_uris)
      IO.write(File.join(output_dir, 'domains.txt'), domains.join("\n"))
      IO.write(File.join(output_dir, 'wildcards.txt'), wildcards.join("\n"))
    end

    private

    def parse_all_uris(uris)
      domains = []
      wildcards = []

      uris.each do |uri|
        uri.split(',').each do |target|
          next unless target.include?('.')

          uri = parse_uri(target)
          uri = parse_uri("http://#{target}") if uri&.host.nil?

          next unless valid_uri?(uri)

          arr = uri.host.include?('*') ? wildcards : domains
          arr << uri.host.downcase
        end
      end

      [domains.uniq, wildcards.uniq]
    end

    def parse_uri(str)
      URI(str)
    rescue URI::InvalidURIError
      nil
    end

    def valid_uri?(uri)
      return false unless uri&.host

      # iOS/Android/FireOS mobile app links
      return false if %w[itunes.apple.com play.google.com www.amazon.com].include?(uri.host)

      # Executable files
      return false if uri.host.end_with?('.exe')

      # Links to source code (except exactly github.com/gitlab.com, which are scopes on hackerone)
      return false if %w[github.com gitlab.com].include?(uri.host) && !['', '/'].include?(uri.path)

      true
    end

    def with_ssh_keys(&_block)
      Dir.mktmpdir do |tmpdir|
        known_hosts_path = File.expand_path(File.join(__dir__, '..', '..', 'config', 'known_hosts'))

        privkey_path = File.join(tmpdir, 'id_rsa')
        IO.write(privkey_path, ENV['SSH_PRIV_KEY'])
        IO.write(File.join(tmpdir, 'id_rsa.pub'), ENV['SSH_PUB_KEY'])

        git_ssh = "\"ssh -i '#{privkey_path}' -o UserKnownHostsFile='#{known_hosts_path}' -o HashKnownHosts='no'\""

        yield git_ssh
      end
    end
  end
end
