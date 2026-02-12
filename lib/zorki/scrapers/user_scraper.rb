# frozen_string_literal: true

require "typhoeus"

module Zorki
  class UserScraper < Scraper
    def parse(username)
      # Stuff we need to get from the DOM (implemented is starred):
      # - *Name
      # - *Username
      # - *No. of posts
      # - *Verified
      # - *No. of followers
      # - *No. of people they follow
      # - *Profile
      #   - *description
      #   - *links
      # - *Profile image

      graphql_script = nil
      count = 0
      loop do
        # login
        print "Scraping user #{username}... (attempt #{count + 1})\n"
        begin
          # This is searching for a specific request, the reason it's weird is because it's uri encoded
          # graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "graphql/query", "data,user,media_count", post_data_include: "render_surface%22%3A%22PROFILE")
          # Logged in is different than logged out
          begin
            graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "graphql/query", "data,user,follower_count")
          rescue Zorki::ContentUnavailableError
            begin
              graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "graphql/query", "data,user,friendship_count")
            rescue Zorki::ContentUnavailableError
              graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "graphql/query", nil, post_data_include: "render_surface%22%3A%22PROFILE", header: { "X-FB-Friendly-Name": "PolarisProfilePageContentQuery" })
            end
          end


          # TODO This is broken apparenlty sometimes
          # debugger if graphql_script.to_s.include?("highlights")

          graphql_script = graphql_script.first if graphql_script.class == Array

          # if graphql_script.nil?
          #   graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "web_profile_info")
          # end
        rescue Zorki::ContentUnavailableError
          count += 1

          if count > 4
            raise Zorki::UserScrapingError.new("Zorki could not find user #{username}", additional_data: { username: username })
          elsif count > 3
            # login
          end

          # page.driver.browser.navigate.to("https://www.instagram.com") # we want to go back to the main page so we start from scratch
          sleep rand(5..10)
          next
        end

        break
      end

      if graphql_script.has_key?("author") && !graphql_script["author"].nil?
        user = graphql_script["author"]

        # Get the username (to verify we're on the right page here)
        scraped_username = user["identifier"]["value"]
        raise Zorki::Error unless username == scraped_username

        number_of_posts = graphql_script["interactionStatistic"].select do |stat|
          ["https://schema.org/FilmAction", "http://schema.org/WriteAction"].include?(stat["interactionType"])
        end.first

        # number_of_posts = graphql_script["data"]["user"]["media_count"] if number_of_posts.nil?

        number_of_followers = graphql_script["interactionStatistic"].select do |stat|
          stat["interactionType"] == "http://schema.org/FollowAction"
        end.first

        # number_of_followers = graphql_script["data"]["user"]["follower_count"] if number_of_followers.nil?

        begin
          profile_image_url = user["image"]
          {
            name: user["name"],
            username: username,
            number_of_posts: Integer(number_of_posts["userInteractionCount"]),
            number_of_followers: Integer(number_of_followers["userInteractionCount"]),
            # number_of_following: user["edge_follow"]["count"],
            verified: user["is_verified"], # todo
            profile: graphql_script["description"],
            profile_link: user["sameAs"],
            profile_image: Zorki.retrieve_media(profile_image_url),
            profile_image_url: profile_image_url
          }
        end
      else
        begin
          user = graphql_script["data"]["user"]
        rescue StandardError
        end

        # Get the username (to verify we're on the right page here)
        scraped_username = user["username"]
        raise Zorki::Error unless username == scraped_username

        profile_image_url = user["hd_profile_pic_url_info"]["url"]
        {
          name: user["full_name"],
          username: username,
          number_of_posts: user["media_count"],
          number_of_followers: user["follower_count"],
          number_of_following: user["following_count"],
          verified: user["is_verified"],
          profile: user["biography"],
          profile_link: user["external_url"],
          profile_image: Zorki.retrieve_media(profile_image_url),
          profile_image_url: profile_image_url
        }
      end
    rescue Zorki::ContentUnavailableError
      raise Zorki::UserScrapingError.new("Zorki could not find user #{username}", additional_data: { username: username })
    end
  end
end
