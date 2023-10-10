import raylib
import std/bitops
import std/streams
import std/strformat
import os

const
  spriteSize = 8
  
  fontset = [0xF0, 0x90, 0x90, 0x90, 0xF0,
             0x20, 0x60, 0x20, 0x20, 0x70,
             0xF0, 0x10, 0xF0, 0x80, 0xF0,
             0xF0, 0x10, 0xF0, 0x10, 0xF0,
             0x90, 0x90, 0xF0, 0x10, 0x10,
             0xF0, 0x80, 0xF0, 0x10, 0xF0,
             0xF0, 0x80, 0xF0, 0x90, 0xF0,
             0xF0, 0x10, 0x20, 0x40, 0x40,
             0xF0, 0x90, 0xF0, 0x90, 0xF0,
             0xF0, 0x90, 0xF0, 0x10, 0xF0,
             0xF0, 0x90, 0xF0, 0x90, 0x90,
             0xE0, 0x90, 0xE0, 0x90, 0xE0,
             0xF0, 0x80, 0x80, 0x80, 0xF0,
             0xE0, 0x90, 0x90, 0x90, 0xE0,
             0xF0, 0x80, 0xF0, 0x80, 0xF0,
             0xF0, 0x80, 0xF0, 0x80, 0x80,
             ]
  
type
  MemoryArray = array[0..4095, int]
  RegisterArray = array[0..15, int]
  VideoArray = array[0..64*32, int]

var
  memory: MemoryArray
  stack: seq[int] = @[] # Top of stack is last value added (high index)
  rom: seq[int] = @[]
  pc = 0x200
  idx_reg = 0
  registers: RegisterArray
  delayTimer = 0
  soundTimer = 0
  paused: bool = false
  video: VideoArray
  index_register: int = 0
  
let
  pixelSize: int32 = 8
  height: int32 = 32
  width: int32 = 64
  
proc readRomFile(filename: string): seq[int] =
  let strm = newFileStream(filename, fmRead)
  var val: int
  var result: seq[int] = @[]
  var address = 0x200
  if not isNil(strm):
    while not strm.atEnd:
      val = strm.readUInt8.int
      result.add(val)
      memory[address] = val
      address += 1
    strm.close()
  return result
  
proc loadFonts() = 
  var address = 0
  for val in fontset:
    #echo fmt"stored {val:x} at address {address:x}"
    memory[address] = val
    address += 1
    
proc cycle() = 
  # Fetch
  var opcode = memory[pc] shl 8 or memory[pc + 1]
  pc += 2
  
  # Decode and execute
  if opcode == 0x00E0: # Clear display
    echo fmt"{opcode:x}: Clear display"
    for i, v in video:
      video[i] = 0
  elif opcode == 0x00EE: # Return from subroutine
    # Move PC to value held on top of the stack
    echo fmt"{opcode:x}: Return from subroutine"
    pc = stack.pop()
  elif opcode shr 12 == 1: # Jump
    var loc = opcode mod 0x1000
    echo fmt"{opcode:x}: Jump to {loc:X}"
    pc = loc
  elif opcode shr 12 == 2: # Call Subroutine
    var loc = opcode mod 0x2000
    echo fmt"{opcode:x}: Call subroutine at {loc:X}"
    stack.add(pc)
  elif opcode shr 12 == 3: # TODO: IMPLEMENT ME!!!!!
    var xkk = opcode mod 0x3000
    echo fmt"{opcode:x}: SE Vx"
  elif opcode shr 12 == 6: # Set register to value
    var xkk = opcode mod 0x1000
    var x = xkk div 0x100
    var kk = xkk mod 0x100
    registers[x] = kk
    echo fmt"{opcode:x}: Set register V{x:x} to {kk:x}"
  elif opcode shr 12 == 7: # Add value to register
    var xkk = opcode mod 0x1000
    var x = xkk div 0x100
    var kk = xkk mod 0x100
    echo fmt"{opcode:x}: Add value {kk:x} to register V{x:x}"
    registers[x] += kk
  elif opcode shr 12 == 0x0A: # Set Index Register to value
    var val = opcode and 0x0FFF
    echo fmt"{opcode:x}: Set register I to {val:x} (points to the value {memory[val]:x})"
    index_register = val
  elif opcode shr 12 == 0x0D: # Display sprite
    var
      x = (opcode div 0x100) mod 0x10
      y = (opcode div 0x10) mod 0x10
      n = opcode mod 0x10
    echo fmt"{opcode:x}: Display {n:x}-byte sprite at memory location I({index_register:x} = {memory[index_register]:x}) at V{x:x}, V{y:x}"
    registers[0xF] = 0
    var row = 0
    var col = 0
    var xpos = registers[x]
    var ypos = registers[y]
    #echo fmt"DRAW Sprite: {memory[index_register]:x}"
    while (row < (opcode and 0xF)):
      col = 0
      var sprite = memory[index_register + row]
      #echo fmt"Row : {sprite:x}"
      while (col < spriteSize):
        var realX = (xpos + col) mod width
        var realY = (ypos + row) mod height
        #echo fmt"Drawing sprite pixel at x={realX}, y={realY}"
        #echo fmt"Sprite pixel: {sprite:x}, sprite and 0x80: {sprite and 0x80:x}"
        
        #echo fmt"Old scr pix:  {video[realX + width*(realY)]}"
        if ((sprite and 0x80) > 0):
          var old = video[realX + width*realY]
          if old > 0:
            registers[0xF] = 1
            video[realX + width*(realY)] = 0
          else:
            video[realX + width*realY] = 1
        #echo fmt"New scr pix:  {video[realX + width*(realY)]}"
        col += 1
        sprite = sprite shl 1
      row += 1
  else:
    echo fmt"opcode {opcode:x} not implemented"
    
  # Decrement
  if delayTimer > 0:
    delayTimer -= 1
  if soundTimer > 0:
    soundTimer -= 1
  
proc printVideo() = 
  var row = 0
  var col = 0
  while row < height:
    var s = "("
    col = 0
    while col < width:
      if video[col + width*row] > 0:
        s = s & "X"
      else:
        s = s & "_"
      col += 1
    s = s & ")"
    echo s
    row += 1

proc main =
  loadFonts()
  rom = readRomFile("/Users/ekish/Desktop/IBMLogo.ch8")
  echo "---------------------"
  
  echo "---------------------"
  var ct = 0
  #while pc < len(memory):
  #  cycle()
  #  ct += 1
  #  if ct > 40: break
  #printVideo()
  # Initialization
  # --------------------------------------------------------------------------------------
  initWindow(width*pixelSize, height*pixelSize, "CHIP-8")
  try:

    when defined(emscripten):
      emscriptenSetMainLoop(updateDrawFrame, 60, 1)
    else:
      setTargetFPS(60)
      # ----------------------------------------------------------------------------------
      # Main game loop
      while not windowShouldClose(): # Detect window close button or ESC key
        # Update and Draw
        echo "CYCLE"
        cycle()
        # --------------------------------------------------------------------------------
        beginDrawing()
        echo "DRAW"
        #printVideo()
        clearBackground(BLACK)
        var ix: int32 = 0
        var iy: int32 = 0
        while iy < 32:
          ix = 0
          while ix < 64:
            if video[ix + width*iy] > 0:
              let px: int32 = ix*pixelSize
              let py: int32 = iy*pixelSize
              drawRectangle(px, py, pixelSize, pixelSize, RAYWHITE)
            ix += 1
          iy += 1
        
        #drawPixel(16, 16)
        endDrawing()
        sleep(200)
        # --------------------------------------------------------------------------------
    # De-Initialization
    # ------------------------------------------------------------------------------------
  finally:
    closeWindow() # Close window and OpenGL context

main()