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
  key_inputs: RegisterArray
  verbose = 0
  
let
  pixelSize: int32 = 8
  height: int32 = 32
  width: int32 = 64
  key_bindings = [KeyboardKey.X, KeyboardKey.One, KeyboardKey.Two, KeyboardKey.Three,
                  KeyboardKey.Q, KeyboardKey.W, KeyboardKey.E,
                  KeyboardKey.A, KeyboardKey.S, KeyboardKey.D,
                  KeyboardKey.Z, KeyboardKey.C, KeyboardKey.Four, KeyboardKey.R, KeyboardKey.F, KeyboardKey.V]
  
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
    if verbose == 1: echo fmt"{opcode:x}: Clear display"
    for i, v in video:
      video[i] = 0
  elif opcode == 0x00EE: # Return from subroutine
    # Move PC to value held on top of the stack
    if verbose == 1: echo fmt"{opcode:x}: Return from subroutine"
    pc = stack.pop()
  # 1xxx CODES---------------------------------
  elif opcode shr 12 == 1: # Jump
    var loc = opcode and 0x0FFF
    if verbose == 1: echo fmt"{opcode:x}: Jump to {loc:X}"
    pc = loc
  # 2xxx CODES---------------------------------
  elif opcode shr 12 == 2: # Call Subroutine
    var loc = opcode and 0x0FFF
    if verbose == 1: echo fmt"{opcode:x}: Call subroutine at {loc:X}"
    stack.add(pc)
    pc = loc
  # 3xxx CODES---------------------------------
  elif opcode shr 12 == 3: # If Vx = kk, increment PC
    var x = (opcode and 0x0F00) shr 8
    var kk = opcode and 0x00FF
    if registers[x] == kk:
      pc += 2
    if verbose == 1: echo fmt"{opcode:x}: 3xkk Skip next if Vx ==  kk"
  # 4xxx CODES---------------------------------
  elif opcode shr 12 == 4: # If V4xkk
    var x = (opcode and 0x0F00) shr 8
    var kk = opcode and 0x00FF
    if registers[x] != kk:
      pc += 2
    if verbose == 1: echo fmt"{opcode:x}: 4xkk Skip next if Vx !=  kk"
  # 5xxx CODES---------------------------------
  elif opcode shr 12 == 5:
    var x = (opcode and 0x0F00) shr 8
    var y = (opcode and 0x00F0) shr 4
    if registers[x] == registers[y]:
      pc += 2
    if verbose == 1: echo fmt"{opcode:x}: 5xy0 Skip next if Vx ==  Vy"
  # 6xxx CODES---------------------------------
  elif opcode shr 12 == 6: # Set register to value
    var xkk = opcode and 0x0FFF
    var x = xkk div 0x100
    var kk = xkk mod 0x100
    registers[x] = kk
    if verbose == 1: echo fmt"{opcode:x}: Set register V{x:x} to {kk:x}"
  # 7xxx CODES---------------------------------
  elif opcode shr 12 == 7: # Add value to register
    var xkk = opcode and 0x0FFF
    var x = (xkk and 0xF00) shr 8
    var kk = xkk and 0x0FF
    if verbose == 1: echo fmt"{opcode:x}: Add value {kk:x} to register V{x:x}"
    var sm = registers[x] + kk
    registers[x] = sm and 0xFF
  # 8xxx CODES---------------------------------
  elif opcode shr 12 == 8:
    var lastbit = opcode and 0x000F
    var x = (opcode and 0x0F00) shr 8
    var y = (opcode and 0x00F0) shr 4
    if lastbit == 0:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{y:x}"
      registers[x] = registers[y]
    elif lastbit == 1:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{x:x} or V{y:x}"
      registers[x] = registers[x] or registers[y]
    elif lastbit == 2:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{x:x} and V{y:x}"
      registers[x] = registers[x] and registers[y]
    elif lastbit == 3:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{x:x} xor V{y:x}"
      registers[x] = registers[x] xor registers[y]
    elif lastbit == 4:
      if verbose == 1: echo fmt"{opcode:x} Add V{x:x} and V{y:x}, set VF as carry"
      var sm = registers[x] + registers[y]
      registers[x] = sm and 0xFF
      if sm > 255:
        registers[0xF] = 1
      else:
        registers[0xF] = 0
    elif lastbit == 5:
      if verbose == 1: echo fmt"{opcode:x} Subtract V{x:x} - V{y:x}, set VF as borrow"
      var diff: uint8 = uint8(registers[x]) - uint8(registers[y])
      if registers[x] < registers[y]:
        registers[0xF] = 1
      else:
        registers[0xF] = 0
      registers[x] = int(diff)
    elif lastbit == 6:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{x:x} shr 1"
      registers[0xF] = registers[x] and 0x1
      registers[x] = registers[x] shr 1
    elif lastbit == 7:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{y:x} - V{x:x}, VF = NOT borrow"
      var diff: uint8 = uint8(registers[y]) - uint8(registers[x])
      if registers[y] < registers[x]:
        registers[0xF] = 1
      else:
        registers[0xF] = 0
      registers[x] = int(diff)
    elif lastbit == 0xE:
      if verbose == 1: echo fmt"{opcode:x} Set V{x:x} = V{x:x} shl 1"
      registers[0xF] = (registers[x] and 0x80) shr 7
      registers[x] = registers[x] shl 1
  # 9xxx CODES---------------------------------
  elif opcode shr 12 == 0x09:
    var x = (opcode and 0x0F00) shr 8
    var y = (opcode and 0x00F0) shr 4
    if verbose == 1: echo fmt"{opcode:x} Skip next instruction if V{x:x} != V{x:x}"
    if registers[x] != registers[y]:
      pc += 2
  # Axxx CODES---------------------------------
  elif opcode shr 12 == 0x0A: # Set Index Register to value
    var val = opcode and 0x0FFF
    if verbose == 1: echo fmt"{opcode:x}: Set register I to {val:x} (points to the value {memory[val]:x})"
    index_register = val
  # Bxxx CODES---------------------------------
  elif opcode shr 12 == 0x0B: # JMP
    var val = opcode and 0x0FFF
    if verbose == 1: echo fmt"{opcode:x}: Jump to location {val:x} + V0 = {val + registers[0]:x}"
    pc = registers[0] + val
    index_register = val
  # Cxxx CODES
  elif opcode shr 12 == 0x0C: # Random byte
    var x = (opcode and 0x0F00) shr 8
    var byte = opcode and 0x00FF
    var rando = rand(255)
    if verbose == 1: echo fmt"{opcode:x}: Set V{x:x} = Random byte {rando:x} and kk = {byte:x}, giving {byte and rando:x}"
    registers[x] = byte and rando
  elif opcode shr 12 == 0x0D: # Display sprite
    var
      x = (opcode div 0x100) mod 0x10
      y = (opcode div 0x10) mod 0x10
      n = opcode mod 0x10
    if verbose == 1: echo fmt"{opcode:x}: Display {n:x}-byte sprite at memory location I({index_register:x} = {memory[index_register]:x}) at V{x:x}, V{y:x}"
    registers[0xF] = 0
    var row = 0
    var col = 0
    var xpos = registers[x]
    var ypos = registers[y]
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
  # Exxx CODES---------------------------------
  elif opcode shr 12 == 0x0E: # Display sprite
    var
      last2bits = (opcode and 0x00FF)
      x = (opcode and 0x0F00) shr 8
    if last2bits == 0x9E:
      if verbose == 1: echo fmt"{opcode:x}: Skip next instruction if key with the value of Vx is pressed."
      if key_inputs[x] == 1:
        pc += 2
    elif last2bits == 0xA1:
      if verbose == 1: echo fmt"{opcode:x}: Skip next instruction if key with the value of Vx is NOT pressed."
      if key_inputs[x] == 0:
        pc += 2
  # Fxxx CODES---------------------------------
  elif opcode shr 12 == 0x0F:
    var
      last2bits = (opcode and 0x00FF)
      x = (opcode and 0x0F00) shr 8
    if last2bits == 0x07:
      if verbose == 1: echo fmt"{opcode:x}: Set V{x:x} = delay timer value"
      registers[x] = delayTimer
    elif last2bits == 0x0A:
      if verbose == 1: echo fmt"{opcode:x}: Wait for key press, store value in V{x:x}"
      if not key_inputs.contains(1):
        pc -= 2
      else:
        for i in countup(0, 15):
          if key_inputs[i] == 1:
            registers[x] = i
            break

    elif last2bits == 0x15:
      if verbose == 1: echo fmt"{opcode:x}: Set delay timer value = V{x:x}"
      delayTimer = registers[x]
    elif last2bits == 0x18:
      if verbose == 1: echo fmt"{opcode:x}: Set sound timer value = V{x:x}"
      soundTimer = registers[x]
    elif last2bits == 0x1E:
      if verbose == 1: echo fmt"{opcode:x}: Set I = I + V{x:x}"
      index_register += registers[x]
    elif last2bits == 0x29:
      if verbose == 1: echo fmt"{opcode:x}: Set I = location of sprite for  digitV{x:x}"
      index_register = 0 + (5 * registers[x]) # Sprites are 5 bits and start at address 0
    elif last2bits == 0x33:
      if verbose == 1: echo fmt"{opcode:x}: Store BCD representation of V{x:x} in memory locations I, I+1, and I+2."
      memory[index_register] = registers[x] div 100
      memory[index_register + 1] = (registers[x] mod 100) div 10
      memory[index_register + 2] = registers[x] mod 10
    elif last2bits == 0x55:
      if verbose == 1: echo fmt"{opcode:x}: Store registers V0 through V{x:x} in memory starting at location I."
      for i in countup(0, x):
        memory[index_register + i] = registers[i]
    elif last2bits == 0x65:
      if verbose == 1: echo fmt"{opcode:x}: Read registers V0 through V{x:x} from memory starting at location I."
      for i in countup(0, x):
        registers[i] = memory[index_register + i]
      
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

proc readKeyInputs() = 
  for i in countup(0, 15):
    if isKeyDown(key_bindings[i]):
      key_inputs[i] = 1
    else:
      key_inputs[i] = 0
  

proc main =
  loadFonts()
  if paramCount() == 1:
    rom = readRomFile(paramStr(1))
  else:
   rom = readRomFile("test_opcode.ch8")
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
      emscriptenSetMainLoop(updateDrawFrame, 600, 1)
    else:
      setTargetFPS(300)
      # ----------------------------------------------------------------------------------
      # Main game loop
      while not windowShouldClose(): # Detect window close button or ESC key
        # Update and Draw
        readKeyInputs()
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