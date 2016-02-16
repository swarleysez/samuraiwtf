#!/usr/bin/env ruby
# encoding: UTF-8

$: << '.'
require File.dirname(__FILE__) + '/lib/wpscan/wpscan_helper'

def main
  # delete old logfile, check if it is a symlink first.
  File.delete(LOG_FILE) if File.exist?(LOG_FILE) and !File.symlink?(LOG_FILE)

  banner()

  begin
    wpscan_options = WpscanOptions.load_from_arguments

    unless wpscan_options.has_options?
      usage()
      raise('No argument supplied')
    end

    if wpscan_options.help
      help()
      usage()
      exit(0)
    end

    if wpscan_options.version
      puts "Current version is #{version}"
      exit(0)
    end

    # Check for updates
    if wpscan_options.update
      if !@updater.nil?
        if @updater.has_local_changes?
          print "#{red('[!]')} Local file changes detected, an update will override local changes, do you want to continue updating? [y/n] "
          Readline.readline =~ /^y/i ? @updater.reset_head : raise('Update aborted')
        end
        puts @updater.update()
      else
        puts 'Svn / Git not installed, or wpscan has not been installed with one of them.'
        puts 'Update aborted'
      end
      exit(0)
    end

    version_mappings = load_version_mappings
    wp_target = WpTarget.new(wpscan_options.url, wpscan_options.to_h.merge(version_mappings: version_mappings))

    # Remote website up?
    unless wp_target.online?
      raise "The SharePoint URL supplied '#{wp_target.uri}' seems to be down."
    end

    if wpscan_options.proxy
      proxy_response = Browser.get(wp_target.url)

      unless WpTarget::valid_response_codes.include?(proxy_response.code)
        raise "Proxy Error :\r\n#{proxy_response.headers}"
      end
    end

    redirection = wp_target.redirection
    if redirection
      if wpscan_options.follow_redirection
        puts "Following redirection #{redirection}"
        puts
      else
        puts "The remote host tried to redirect us to #{redirection}"
        print 'Do you want follow the redirection ? [y/n] '
      end

      if wpscan_options.follow_redirection or Readline.readline =~ /^y/i
        wpscan_options.url = redirection
        wp_target = WpTarget.new(redirection, wpscan_options.to_h.merge(version_mappings: version_mappings))
      else
        puts 'Scan aborted'
        exit(0)
      end
    end

    if wp_target.has_basic_auth? && wpscan_options.basic_auth.nil?
      raise 'Basic authentication is required, please provide it with --basic-auth <login:password>'
    end

    # Remote website is wordpress?
    unless wpscan_options.force
      unless wp_target.sharepoint?
        raise 'The remote website is up, but does not seem to be running SharePoint.'
      end
    end

    # Output runtime data
    start_time = Time.now
    puts "| URL: #{wp_target.url}"
    puts "| Started on #{start_time.asctime}"
    puts

    if wp_target.has_robots?
      puts green('[+]') + " robots.txt available under '#{wp_target.robots_url}'"

      wp_target.parse_robots_txt.each do |dir|
        puts "#{green('[+]')} Interesting entry from robots.txt: #{dir}"
      end
    end

    if wp_target.has_readme?
      puts red('[!]') + " The WordPress '#{wp_target.readme_url}' file exists"
    end

    if wp_target.has_full_path_disclosure?
      puts red('[!]') + " Full Path Disclosure (FPD) in '#{wp_target.full_path_disclosure_url}'"
    end

    if wp_target.has_debug_log?
      puts red('[!]') + " Debug log file found : #{wp_target.debug_log_url}"
    end

    wp_target.config_backup.each do |file_url|
      puts red("[!] A wp-config.php backup file has been found '#{file_url}'")
    end

    if wp_target.search_replace_db_2_exists?
      puts red("[!] searchreplacedb2.php has been found '#{wp_target.search_replace_db_2_url}'")
    end

    wp_target.interesting_headers.each do |header|
      output = "#{green('[+]')} Interesting header: "

      if header[1].class == Array 
        header[1].each do |value|
          puts output + "#{header[0]}: #{value}"
        end
      else
        puts output + "#{header[0]}: #{header[1]}"
      end
    end

    if wp_target.multisite?
      puts green('[+]') + ' This site seems to be a multisite (http://codex.wordpress.org/Glossary#Multisite)'
    end

    if wp_target.registration_enabled?
      puts green('[+]') + ' User registration is enabled'
    end

    if wp_target.has_xml_rpc?
      puts green('[+]') + " XML-RPC Interface available under #{wp_target.xml_rpc_url}"
    end

    if wp_target.has_malwares?
      malwares = wp_target.malwares
      puts red('[!]') + " #{malwares.size} malware(s) found :"

      malwares.each do |malware_url|
        puts
        puts ' | ' + red("#{malware_url}")
      end
      puts
    end

    enum_options = {
      show_progression: true,
      exclude_content:  wpscan_options.exclude_content_based
    }

    puts green('[+]') + " The SharePoint version is #{wp_target.version}"

    if wp_target.has_vulnerabilities?
      puts green('[+]') + " Vulnerabilities"
      wp_target.vulnerabilities.each do |vuln|
        puts "Title: #{vuln.title}"
        puts "References:"
        vuln.references.each do |ref|
          puts "\t#{ref}"
        end
        puts "Type: #{vuln.type}"
      end
    end


    if wp_theme = wp_target.theme
      puts
      # Theme version is handled in #to_s
      puts green('[+]') + " The WordPress theme in use is #{wp_theme}"
      wp_theme.output
    end

    # Enumerate installed themes
    if wpscan_options.enumerate_themes or wpscan_options.enumerate_only_vulnerable_themes or wpscan_options.enumerate_all_themes
      puts
      puts green('[+]') + " Enumerating installed themes #{'(only vulnerable ones)' if wpscan_options.enumerate_only_vulnerable_themes} ..."
      puts

      wp_themes = WpThemes.aggressive_detection(wp_target,
        enum_options.merge(
          file: wpscan_options.enumerate_all_themes ? THEMES_FULL_FILE : THEMES_FILE,
          only_vulnerable: wpscan_options.enumerate_only_vulnerable_themes || false
        )
      )
      puts
      if !wp_themes.empty?
        puts green('[+]') + " We found #{wp_themes.size} themes:"

        wp_themes.output
      else
        puts 'No themes found :('
      end
    end

    if wpscan_options.enumerate_timthumbs
      puts
      puts green('[+]') + ' Enumerating timthumb files ...'
      puts

      wp_timthumbs = WpTimthumbs.aggressive_detection(wp_target,
        enum_options.merge(
          file: DATA_DIR + '/timthumbs.txt',
          theme_name: wp_theme ? wp_theme.name : nil
        )
      )
      puts
      if !wp_timthumbs.empty?
        puts green('[+]') + " We found #{wp_timthumbs.size} timthumb file/s :"
        puts

        wp_timthumbs.output

        puts
        puts red(' * Reference: http://www.exploit-db.com/exploits/17602/')
      else
        puts 'No timthumb files found :('
      end
    end

    # If we haven't been supplied a username, enumerate them...
    if !wpscan_options.username and wpscan_options.wordlist or wpscan_options.enumerate_usernames
      puts
      puts green('[+]') + ' Enumerating usernames ...'

      wp_users = WpUsers.aggressive_detection(wp_target,
        enum_options.merge(
          range: wpscan_options.enumerate_usernames_range,
          show_progression: false
        )
      )

      if wp_users.empty?
        puts 'We did not enumerate any usernames :('

        if wpscan_options.wordlist
          puts 'Try supplying your own username with the --username option'
          puts
          exit(1)
        end
      else
        puts green('[+]') + " We found the following #{wp_users.size} user/s :"
        wp_users.output(margin_left: ' ' * 4)
      end

    else
      # FIXME : Change the .username to .login (and also the --username in the CLI)
      wp_users = WpUsers.new << WpUser.new(wp_target.uri, login: wpscan_options.username)
    end

    # Start the brute forcer
    bruteforce = true
    if wpscan_options.wordlist
      if wp_target.has_login_protection?

        protection_plugin = wp_target.login_protection_plugin()

        puts
        puts "The plugin #{protection_plugin.name} has been detected. It might record the IP and timestamp of every failed login and/or prevent brute forcing altogether. Not a good idea for brute forcing !"
        print '[?] Do you want to start the brute force anyway ? [y/n] '

        bruteforce = false if Readline.readline !~ /^y/i
      end
      puts
      if bruteforce
        puts green('[+]') + ' Starting the password brute forcer'

        begin
          wp_users.brute_force(
            wpscan_options.wordlist,
            show_progression: true,
            verbose: wpscan_options.verbose
          )
        ensure
          puts
          wp_users.output(show_password: true, margin_left: ' ' * 2)
        end
      else
        puts 'Brute forcing aborted'
      end
    end

    stop_time = Time.now
    puts
    puts green("[+] Finished at #{stop_time.asctime}")
    elapsed = stop_time - start_time
    puts green("[+] Elapsed time: #{Time.at(elapsed).utc.strftime('%H:%M:%S')}")
    exit(0) # must exit!

  rescue SystemExit, Interrupt
    puts 'Exiting!'
  rescue => e
    if e.backtrace[0] =~ /main/
      puts red(e.message)
    else
      puts red("[ERROR] #{e.message}")
      puts red('Trace :')
      puts red(e.backtrace.join("\n"))
    end
    exit(1)
  end
end

main()