function love.conf(t)
  t.window.fullscreen = love._os == "Android" or love._os == "iOS"
end