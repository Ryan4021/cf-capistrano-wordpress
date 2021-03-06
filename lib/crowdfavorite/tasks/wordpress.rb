require 'crowdfavorite/tasks'
require 'Shellwords'

module CrowdFavorite::Tasks::WordPress
  extend CrowdFavorite::Support::Namespace
  namespace :cf do
    def _cset(name, *args, &block)
      unless exists?(name)
        set(name, *args, &block)
      end
    end

    _cset :copy_exclude, [
      ".git", ".gitignore", ".gitmodules",
      ".DS_Store", ".svn", 
      "Capfile", "/config",
      "capinfo.json",
    ]

    _cset :wp_symlinks, [{
      "cache" => "wp-content/cache",
      "uploads" => "wp-content/uploads",
      "blogs.dir" => "wp-content/blogs.dir",
    }] 

    _cset :wp_configs, [{
      "db-config.php" => "wp-content/",
      "advanced-cache.php" => "wp-content/",
      "object-cache.php" => "wp-content/",
      "*.html" => "/",
    }]

    before   "deploy:finalize_update", "cf:wordpress:generate_config"
    after    "deploy:finalize_update", "cf:wordpress:touch_release"
    after    "cf:wordpress:generate_config", "cf:wordpress:link_symlinks"
    after    "cf:wordpress:link_symlinks", "cf:wordpress:copy_configs"
    after    "cf:wordpress:copy_configs", "cf:wordpress:install"
    namespace :wordpress do

      namespace :install do

        desc <<-DESC
              [internal] Installs WordPress with a remote svn cache
        DESC
        task :with_remote_cache, :except => { :no_release => true } do
          wp = fetch(:wordpress_version, "trunk")
          wp_target = fetch(:wp_path, release_path)
          wp_stage = File.join(shared_path, "wordpress", wp)
          # check out cache of wordpress code
          run Shellwords::shelljoin(["test", "-e", wp_stage]) +
            " || " + Shellwords::shelljoin(["svn", "co", "-q", "http://core.svn.wordpress.org/" + wp, wp_stage])
          # update branches or trunk (no need to update tags)
          run Shellwords::shelljoin(["svn", "up", "--force", "-q", wp_stage]) unless wp.start_with?("tags/")
          # ensure a clean copy
          run Shellwords::shelljoin(["svn", "revert", "-R", "-q", wp_stage])
          # trailingslashit for rsync
          wp_stage << '/' unless wp_stage[-1..-1] == '/'
          # push wordpress into the right place (release_path by default, could be #{release_path}/wp)
          run Shellwords::shelljoin(["rsync", "--exclude=.svn", "--ignore-existing", "-a", wp_stage, wp_target])
        end

        desc <<-DESC
              [internal] Installs WordPress with a local svn cache/copy, compressing and uploading a snapshot
        DESC
        task :with_copy, :except => { :no_release => true } do
          wp = fetch(:wordpress_version, "trunk")
          wp_target = fetch(:wp_path, release_path)
          Dir.mktmpdir do |tmp_dir|
            tmpdir = fetch(:cf_database_store, tmp_dir)
            wp = fetch(:wordpress_version, "trunk")
            Dir.chdir(tmpdir) do 
              if !(wp.start_with?("tags/") || wp.start_with?("branches/") || wp == "trunk")
                wp = "branches/#{wp}"
              end
              wp_stage = File.join(tmpdir, "wordpress", wp)
              ["branches", "tags"].each do |wpsvntype|
                system Shellwords::shelljoin(["mkdir", "-p", File.join(tmpdir, "wordpress", wpsvntype)])
              end

              puts "Getting WordPress #{wp} to #{wp_stage}"
              system Shellwords::shelljoin(["test", "-e", wp_stage]) +
                " || " + Shellwords::shelljoin(["svn", "co", "-q", "http://core.svn.wordpress.org/" + wp, wp_stage])
              system Shellwords::shelljoin(["svn", "up", "--force", "-q", wp_stage]) unless wp.start_with?("tags/")
              system Shellwords::shelljoin(["svn", "revert", "-R", "-q", wp_stage])
              wp_stage << '/' unless wp_stage[-1..-1] == '/'
              Dir.mktmpdir do |copy_dir|
                comp = Struct.new(:extension, :compress_command, :decompress_command)
                remote_tar = fetch(:copy_remote_tar, 'tar')
                local_tar = fetch(:copy_local_tar, 'tar')
                type = fetch(:copy_compression, :gzip)
                compress = case type
                           when :gzip, :gz   then comp.new("tar.gz",  [local_tar, '-c -z --exclude .svn -f'], [remote_tar, '-x -k -z -f'])
                           when :bzip2, :bz2 then comp.new("tar.bz2", [local_tar, '-c -j --exclude .svn -f'], [remote_tar, '-x -k -j -f'])
                           when :zip         then comp.new("zip",     %w(zip -qyr), %w(unzip -q))
                           else raise ArgumentError, "invalid compression type #{type.inspect}"
                           end
                compressed_filename = "wp-" + File.basename(fetch(:release_path)) + "." + compress.extension
                local_file = File.join(copy_dir, compressed_filename)
                puts "Compressing #{wp_stage} to #{local_file}"
                Dir.chdir(wp_stage) do
                  system([compress.compress_command, local_file, '.'].join(' '))
                end
                remote_file = File.join(fetch(:copy_remote_dir, '/tmp'), File.basename(local_file))
                puts "Pushing #{local_file} to #{remote_file} to deploy"
                upload(local_file, remote_file)
                wp_target = fetch(:wp_path, fetch(:release_path))
                run("mkdir -p #{wp_target} && cd #{wp_target} && (#{compress.decompress_command.join(' ')} #{remote_file} || echo 'tar errors for normal conditions') && rm #{remote_file}")
              end

            end
          end
        end

        desc <<-DESC
              [internal] Installs WordPress to the application deploy point
        DESC
        task :default, :except => { :no_release => true } do
          if fetch(:strategy).class <= Capistrano::Deploy::Strategy.new(:remote).class
            with_remote_cache
          else
            with_copy
          end
        end
      end

      desc <<-DESC
              [internal] (currently unused) Generate config files if appropriate
      DESC
      task :generate_config, :except => { :no_release => true } do
        # live config lives in wp-config.php; dev config loaded with local-config.php
        # this method does nothing for now
      end

      desc <<-DESC
              [internal] Symlinks specified files (usually uploads/blogs.dir/cache directories)
      DESC
      task :link_symlinks, :except => { :no_release => true } do
        fetch(:wp_symlinks, []).each do |symlink_group|
          symlink_group.each do |src, targ|
            src = File.join(shared_path, src) unless src.include?(shared_path)
            targ = File.join(release_path, targ) unless targ.include?(release_path)
            run Shellwords::shelljoin(["test", "-e", src]) + " && " + Shellwords::shelljoin(["ln", "-nsf", src, targ]) + " || true"
          end
        end
      end

      desc <<-DESC
              [internal] Copies specified files (usually advanced-cache, object-cache, db-config)
      DESC
      task :copy_configs, :except => { :no_release => true } do
        fetch(:wp_configs, []).each do |config_group|
          config_group.each do |src, targ|
            src = File.join(shared_path, src) unless src.include?(shared_path)
            targ = File.join(release_path, targ) unless targ.include?(release_path)
            run "ls -d #{src} >/dev/null 2>&1 && cp -urp #{src} #{targ} || true"
            #run Shellwords::shelljoin(["test", "-e", src]) + " && " + Shellwords::shelljoin(["cp", "-rp", src, targ]) + " || true"
          end
        end
      end

      desc <<-DESC
              [internal] Ensure the release path has an updated modified time for deploy:cleanup
      DESC
      task :touch_release, :except => { :no_release => true } do
        run "touch '#{release_path}'"
      end
    end

    #===========================================================================
    # util / debugging code

    namespace :debugging do

      namespace :release_info do
        desc <<-DESC
            [internal] Debugging info about releases.
        DESC

        task :default do
          %w{releases_path shared_path current_path release_path releases previous_release current_revision latest_revision previous_revision latest_release}.each do |var|
            puts "#{var}: #{eval(var)}"
          end
        end
      end
    end
  end
end

