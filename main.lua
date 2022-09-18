
-- debugging support (/pkulchenko/MobDebug setup, works also in ZeroBrane Studio)

-- https://github.com/pkulchenko/MobDebug/blob/master/examples/start.lua
-- https://raw.githubusercontent.com/pkulchenko/MobDebug/master/src/mobdebug.lua

-- don't activate debugging if not specified this way
if arg[#arg]=="-debug" then
  -- activate debugging
  require("mobdebug").start()
end
------------------------------------------------------------
function load_map(file_path)
  grid={}
  local line_count=1
  for line in love.filesystem.lines(file_path) do
    local row={}
    for i=1,#line do
      local char=line:sub(i,i)
      if char=="P" then
        px=i
        py=line_count
        char=" "
      end
      table.insert(row,char)
    end
    table.insert(grid,row)
    line_count=line_count+1
  end
end

function love.load()
  tile_size=32*2
	local player=love.graphics.newImage("assets/P.bmp")
  local space=love.graphics.newImage("assets/-.bmp")
  local wall=love.graphics.newImage("assets/W.bmp")
  local exit=love.graphics.newImage("assets/E.bmp")
  tile={P=player,[" "]=space,["#"]=wall,E=exit}
  map={"01","02","03"}
  map_current=0
  next_map()
end
function next_map()
  map_current=1+map_current
  load_map("assets/map"..map[map_current]..".txt")
end

-- draw image scaled and fitting rectangle
function image_draw(image,xywh)
  -- scale factors
  local sx=xywh[3]/image:getWidth()
  local sy=xywh[4]/image:getHeight()
  -- provide image, position, scale
  love.graphics.draw(image, xywh[1],xywh[2],0, sx,sy)
end

function love.draw()
  for y=1,#grid do
    for x=1,#grid[1] do
      local tile_type=grid[y][x]
      if x==px and y==py then tile_type="P" end
      --love.graphics.draw(tile[tile_type],(x-1)*tile_size,(y-1)*tile_size)
      local dx,dy=(x-1)*tile_size,(y-1)*tile_size
      image_draw(tile[tile_type],{dx,dy,tile_size,tile_size})
    end
  end
end

function love.update()
  if love.mouse.isDown(1) then
    local mx,my=love.mouse.getPosition()
    local tx,ty=math.floor(mx/tile_size)+1,math.floor(my/tile_size)+1
    
    if grid[ty]~=nil and grid[ty][tx]~=nil then
      if
      (math.abs(tx-px)==1 and ty==py)
      or (math.abs(ty-py)==1 and tx==px)
      then
        local going=grid[ty][tx]
        if going~="#" then
          px,py=tx,ty
          if going=="E" then next_map() end
        end
      end
    end
  
  end
end
