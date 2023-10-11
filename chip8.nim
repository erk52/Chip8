import raylib
import std/bitops
import std/random
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
  key_pressed: int = -1
  
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
    var loc = opcode and 0x0FFF
    echo fmt"{opcode:x}: Jump to {loc:X}"
    pc = loc
  elif opcode shr 12 == 2: # Call Subroutine
    var loc = opcode and 0x0FFF
    echo fmt"{opcode:x}: Call subroutine at {loc:X}"
    stack.add(pc)
    pc = loc
  elif opcode shr 12 == 3: # If Vx = kk, increment PC
    var x = (opcode and 0x0F00) shr 8
    var kk = opcode and 0x00FF
    if registers[x] == kk:
      pc += 2
    echo fmt"{opcode:x}: 3xkk Skip next if Vx ==  kk"
  elif opcode shr 12 == 4: # If V4xkk
    var x = (opcode and 0x0F00) shr 8
    var kk = opcode and 0x00FF
    if registers[x] != kk:
      pc += 2
    echo fmt"{opcode:x}: 4xkk Skip next if Vx !=  kk"
  elif opcode shr 12 == 5:
    var x = (opcode and 0x0F00) shr 8
    var y = (opcode and 0x00F0) shr 4
    if registers[x] == registers[y]:
      pc += 2
    echo fmt"{opcode:x}: 5xy0 Skip next if Vx ==  Vy"
  elif opcode shr 12 == 6: # Set register to value
    var xkk = opcode and 0x0FFF
    var x = xkk div 0x100
    var kk = xkk mod 0x100
    registers[x] = kk
    echo fmt"{opcode:x}: Set register V{x:x} to {kk:x}"
  elif opcode shr 12 == 7: # Add value to register
    var xkk = opcode and 0x0FFF
    var x = xkk div 0x100
    var kk = xkk mod 0x100
    echo fmt"{opcode:x}: Add value {kk:x} to register V{x:x}"
    registers[x] += kk
  elif opcode shr 12 == 8:
    var lastbit = opcode and 0x000F
    var x = (opcode and 0x0F00) shr 8
    var y = (opcode and 0x00F0) shr 4
    if lastbit == 0:
      echo fmt"{opcode:x} Set V{x:x} = V{y:x}"
      registers[x] = registers[y]
    elif lastbit == 1:
      echo fmt"{opcode:x} Set V{x:x} = V{x:x} or V{y:x}"
      registers[x] = registers[x] or registers[y]
    elif lastbit == 2:
      echo fmt"{opcode:x} Set V{x:x} = V{x:x} and V{y:x}"
      registers[x] = registers[x] and registers[y]
    elif lastbit == 3:
      echo fmt"{opcode:x} Set V{x:x} = V{x:x} xor V{y:x}"
      registers[x] = registers[x] xor registers[y]
    elif lastbit == 4:
      echo fmt"{opcode:x} Add V{x:x} and V{y:x}, set VF as carry"
      var sm = registers[x] + registers[y]
      registers[x] = sm mod 255
      registers[0xF] = sm div 255
    elif lastbit == 5:
      echo fmt"{opcode:x} Subtract V{x:x} - V{y:x}, set VF as borrow"
      var diff: uint8 = uint8(registers[x]) - uint8(registers[y])
      if registers[x] < registers[y]:
        registers[0xF] = 1
      else:
        registers[0xF] = 0
      registers[x] = int(diff)
    elif lastbit == 6:
      echo fmt"{opcode:x} Set V{x:x} = V{x:x} shr 1"
      registers[0xF] = registers[x] and 0x1
      registers[x] = registers[x] shr 1
    elif lastbit == 7:
      echo fmt"{opcode:x} Set V{x:x} = V{y:x} - V{x:x}, VF = NOT borrow"
      var diff: uint8 = uint8(registers[y]) - uint8(registers[x])
      if registers[y] > registers[x]:
        registers[0xF] = 1
      else:
        registers[0xF] = 0
      registers[x] = int(diff)
    elif lastbit == 0xE:
      echo fmt"{opcode:x} Set V{x:x} = V{x:x} shl 1"
      registers[0xF] = (registers[x] and 0x80) shr 7
      registers[x] = registers[x] shl 1
  elif opcode shr 12 == 9:
    var x = (opcode and 0x0F00) shr 8
    var y = (opcode and 0x00F0) shr 4
    echo fmt"{opcode:x} Skip next instruction if V{x:x} != V{x:x}"
    if registers[x] != registers[y]:
      pc += 2
  elif opcode shr 12 == 0x0A: # Set Index Register to value
    var val = opcode and 0x0FFF
    echo fmt"{opcode:x}: Set register I to {val:x} (points to the value {memory[val]:x})"
    index_register = val
  elif opcode shr 12 == 0x0B: # JMP
    var val = opcode and 0x0FFF
    echo fmt"{opcode:x}: Jump to location {val:x} + V0 = {val + registers[0]:x}"
    pc = registers[0] + val
    index_register = val
  elif opcode shr 12 == 0x0C: # Random byte
    var x = opcode and 0x0F00
    var byte = opcode and 0x00FF
    var rando = rand(255)
    echo fmt"{opcode:x}: Set V{x:x} = Random byte {rando:x} and kk = {byte:x}, giving {byte and rando:x}"
    registers[x] = byte and rando
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
      while (col < spriteSize):
        var realX = (xpos + col) mod width
        var realY = (ypos + row) mod height
        
        if ((sprite and 0x80) > 0):
          var old = video[realX + width*realY]
          if old > 0:
            registers[0xF] = 1
            video[realX + width*(realY)] = 0
          else:
            video[realX + width*realY] = 1
        col += 1
        sprite = sprite shl 1
      row += 1
  elif opcode shr 12 == 0x0E: # Display sprite
    var
      last2bits = (opcode and 0x00FF)
      x = (opcode and 0x0F00) shr 8
    if last2bits == 0x9E:
      echo fmt"{opcode:x}: Skip next instruction if key with the value of Vx is pressed."
      # TODO: IMPLEMENT KEY PRESSES!
    elif last2bits == 0xA1:
      echo fmt"{opcode:x}: Skip next instruction if key with the value of Vx is NOT pressed."
      # TODO: IMPLEMENT KEY PRESSES!
  elif opcode shr 12 == 0x0F:
    var
      last2bits = (opcode and 0x00FF)
      x = (opcode and 0x0F00) shr 8
    if last2bits == 0x07:
      echo fmt"{opcode:x}: Set V{x:x} = delay timer value"
      registers[x] = delayTimer
    elif last2bits == 0x0A:
      echo fmt"{opcode:x}: Wait for key press, store value in V{x:x}"
      # TODO: IMPLEMENT KEY PRESSES!
      if key_pressed == -1:
        pc -= 2
      else:
        registers[x] = key_pressed
    elif last2bits == 0x15:
      echo fmt"{opcode:x}: Set delay timer value = V{x:x}"
      delayTimer = registers[x]
    elif last2bits == 0x18:
      echo fmt"{opcode:x}: Set sound timer value = V{x:x}"
      soundTimer = registers[x]
    elif last2bits == 0x1E:
      echo fmt"{opcode:x}: Set I = I + V{x:x}"
      index_register += registers[x]
    elif last2bits == 0x29:
      echo fmt"{opcode:x}: Set I = location of sprite for  digitV{x:x}"
      index_register = 0 + (5 * registers[x]) # Sprites are 5 bits and start at address 0
      
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
  rom = readRomFile("/Users/ekish/Desktop/tetris.ch8")
  echo "---------------------"
  echo rom
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
        cycle()
        # --------------------------------------------------------------------------------
        beginDrawing()
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
        #sleep(200)
        # --------------------------------------------------------------------------------
    # De-Initialization
    # ------------------------------------------------------------------------------------
  finally:
    closeWindow() # Close window and OpenGL context

main()