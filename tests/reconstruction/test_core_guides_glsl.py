"""Original-kernel GLSL parity gate; --software-gl also executes Mesa/EGL compute.

Software execution validates compilation, formats, bindings and numeric fixtures.
It does not qualify Windows WGL, cross-process imports, NR, GPU speed or display.
"""
import argparse
import ctypes as C
import importlib.util
import math
import os
from pathlib import Path
import struct

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('guide_generator',ROOT/'Beta/reconstruction/generate_guides_glsl.py')
generator=importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

def source_contract():
 source=generator.SOURCE.read_bytes()
 assert generator.HEADER.read_bytes()==generator.generated(source),'Stale GLSL header'
 generator_bytes=generator.normalized_text_bytes(Path(generator.__file__).read_bytes())
 assert generator.normalized_text_bytes(generator_bytes.replace(b'\n',b'\r\n'))==generator_bytes,'Generator provenance changes with checkout line endings'
 normalized_source=generator.normalized_text_bytes(source)
 assert generator.generated(normalized_source.replace(b'\n',b'\r\n'))==generator.generated(normalized_source),'Generated GLSL changes with source line endings'
 variants=generator.shaders(source)
 assert len(variants)==3
 for name,code in variants.items():
  assert f'void main() {{ {name}(gl_GlobalInvocationID); }}' in code
  assert 'binding=0) uniform FrameConstants' in code
  assert code.count('imageStore(')==5
  assert 'texelFetch(sceneDepth,' in code and 'sourcePixel.y=depthHeight-1u-sourcePixel.y' in code
 # Meaningful negative gate: a changed ABI cannot silently generate an old UBO.
 bad=source.replace(b'uint depthWidth, depthHeight;',b'uint depthWidth, depthHeight, extra;')
 try:generator.shaders(bad)
 except ValueError:pass
 else:raise AssertionError('Unsupported constant ABI accepted')
 print('PASS: original HLSL/GLSL generation, three entry points and unsupported-ABI rejection')
 return variants

class SoftwareGL:
 def __init__(self):
  # Linux CI normally resolves the system Mesa EGL runtime. Windows CI can
  # point at a portable Mesa build without installing or replacing OpenGL:
  # OPTISHADE_EGL_LIBRARY=<path to libEGL.dll> and optionally
  # OPTISHADE_EGL_DLL_DIR=<directory containing its dependent Mesa DLLs>.
  self._dll_directory=None
  dll_directory=os.environ.get('OPTISHADE_EGL_DLL_DIR')
  if os.name=='nt' and dll_directory:
   self._dll_directory=os.add_dll_directory(dll_directory)
  library=os.environ.get('OPTISHADE_EGL_LIBRARY') or ('libEGL.dll' if os.name=='nt' else 'libEGL.so.1')
  self.egl=C.CDLL(library)
  self.egl.eglGetProcAddress.argtypes=[C.c_char_p];self.egl.eglGetProcAddress.restype=C.c_void_p
  get_display=self.function('eglGetPlatformDisplayEXT',C.c_void_p,C.c_uint,C.c_void_p,C.POINTER(C.c_int))
  self.display=get_display(0x31DD,None,None) # EGL_PLATFORM_SURFACELESS_MESA
  initialize=self.native('eglInitialize',C.c_uint,C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_int))
  major=C.c_int();minor=C.c_int()
  assert initialize(self.display,C.byref(major),C.byref(minor)),'EGL initialize failed'
  bind=self.native('eglBindAPI',C.c_uint,C.c_uint)
  assert bind(0x30A2),'EGL OpenGL binding failed'
  choose=self.native('eglChooseConfig',C.c_uint,C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_void_p),C.c_int,C.POINTER(C.c_int))
  attrib=(C.c_int*7)(0x3033,1,0x3040,8,0x3024,8,0x3038)
  config=C.c_void_p();count=C.c_int()
  assert choose(self.display,attrib,C.byref(config),1,C.byref(count)) and count.value,'No GL configuration'
  create=self.native('eglCreateContext',C.c_void_p,C.c_void_p,C.c_void_p,C.c_void_p,C.POINTER(C.c_int))
  attrs=(C.c_int*7)(0x3098,4,0x30FB,3,0x30FD,1,0x3038)
  self.context=create(self.display,config,None,attrs)
  assert self.context,'No OpenGL 4.3 core context'
  self.make_current=self.native('eglMakeCurrent',C.c_uint,C.c_void_p,C.c_void_p,C.c_void_p,C.c_void_p)
  assert self.make_current(self.display,None,None,self.context),'Could not make software GL current'
  self.get_string=self.function('glGetString',C.c_char_p,C.c_uint)
  self.renderer=self.get_string(0x1F01).decode()
  # A software-only gate must never quietly claim a physical adapter test.
  assert any(x in self.renderer.lower() for x in ('llvmpipe','softpipe','software')),self.renderer
  self.programs=[];self.textures=[];self.buffers=[]

 def native(self,name,result,*args):
  fn=getattr(self.egl,name);fn.restype=result;fn.argtypes=args;return fn

 def function(self,name,result,*args):
  address=self.egl.eglGetProcAddress(name.encode());assert address,name
  return C.CFUNCTYPE(result,*args)(address)

 def compile(self,source):
  shader=self.function('glCreateShader',C.c_uint,C.c_uint)(0x91B9)
  string=C.c_char_p(source.encode())
  self.function('glShaderSource',None,C.c_uint,C.c_int,C.POINTER(C.c_char_p),C.POINTER(C.c_int))(shader,1,C.byref(string),None)
  self.function('glCompileShader',None,C.c_uint)(shader)
  ok=C.c_int();self.function('glGetShaderiv',None,C.c_uint,C.c_uint,C.POINTER(C.c_int))(shader,0x8B81,C.byref(ok))
  if not ok.value:
   log=C.create_string_buffer(16384)
   self.function('glGetShaderInfoLog',None,C.c_uint,C.c_int,C.POINTER(C.c_int),C.c_void_p)(shader,len(log),None,log)
   raise AssertionError(log.value.decode())
  program=self.function('glCreateProgram',C.c_uint)()
  self.function('glAttachShader',None,C.c_uint,C.c_uint)(program,shader)
  self.function('glLinkProgram',None,C.c_uint)(program)
  self.function('glGetProgramiv',None,C.c_uint,C.c_uint,C.POINTER(C.c_int))(program,0x8B82,C.byref(ok))
  self.function('glDeleteShader',None,C.c_uint)(shader)
  if not ok.value:
   log=C.create_string_buffer(16384)
   self.function('glGetProgramInfoLog',None,C.c_uint,C.c_int,C.POINTER(C.c_int),C.c_void_p)(program,len(log),None,log)
   raise AssertionError(log.value.decode())
  self.programs.append(program);return program

 def texture(self,w,h,fmt,channels,data=None):
  name=C.c_uint();self.function('glGenTextures',None,C.c_int,C.POINTER(C.c_uint))(1,C.byref(name))
  self.function('glBindTexture',None,C.c_uint,C.c_uint)(0x0DE1,name)
  self.function('glTexStorage2D',None,C.c_uint,C.c_int,C.c_uint,C.c_int,C.c_int)(0x0DE1,1,fmt,w,h)
  for key in (0x2800,0x2801):self.function('glTexParameteri',None,C.c_uint,C.c_uint,C.c_int)(0x0DE1,key,0x2600)
  value=(name.value,w,h,fmt,channels);self.textures.append(name.value)
  if data is not None:self.upload(value,data)
  return value

 def upload(self,texture,data):
  name,w,h,fmt,channels=texture
  assert len(data)==w*h*channels
  values=(C.c_float*len(data))(*data)
  self.function('glBindTexture',None,C.c_uint,C.c_uint)(0x0DE1,name)
  self.function('glTexSubImage2D',None,C.c_uint,C.c_int,C.c_int,C.c_int,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_void_p)(
   0x0DE1,0,0,0,w,h,{1:0x1903,2:0x8227,4:0x1908}[channels],0x1406,values)

 def read(self,texture):
  name,w,h,fmt,channels=texture;values=(C.c_float*(w*h*channels))()
  self.function('glBindTexture',None,C.c_uint,C.c_uint)(0x0DE1,name)
  self.function('glGetTexImage',None,C.c_uint,C.c_int,C.c_uint,C.c_uint,C.c_void_p)(0x0DE1,0,{1:0x1903,2:0x8227,4:0x1908}[channels],0x1406,values)
  return list(values)

 def run(self,program,inputs,outputs,constants,x,y):
  self.function('glUseProgram',None,C.c_uint)(program)
  for unit,tex in enumerate(inputs):
   self.function('glActiveTexture',None,C.c_uint)(0x84C0+unit)
   self.function('glBindTexture',None,C.c_uint,C.c_uint)(0x0DE1,tex[0])
   self.function('glBindSampler',None,C.c_uint,C.c_uint)(unit,0)
  for unit,tex in enumerate(outputs):
   self.function('glBindImageTexture',None,C.c_uint,C.c_uint,C.c_int,C.c_ubyte,C.c_int,C.c_uint,C.c_uint)(unit,tex[0],0,0,0,0x88BA,tex[3])
  if not self.buffers:
   buffer=C.c_uint();self.function('glGenBuffers',None,C.c_int,C.POINTER(C.c_uint))(1,C.byref(buffer));self.buffers.append(buffer.value)
  raw=C.create_string_buffer(constants)
  self.function('glBindBuffer',None,C.c_uint,C.c_uint)(0x8A11,self.buffers[0])
  self.function('glBufferData',None,C.c_uint,C.c_ssize_t,C.c_void_p,C.c_uint)(0x8A11,len(constants),raw,0x88E8)
  self.function('glBindBufferBase',None,C.c_uint,C.c_uint,C.c_uint)(0x8A11,0,self.buffers[0])
  self.function('glDispatchCompute',None,C.c_uint,C.c_uint,C.c_uint)(x,y,1)
  self.function('glMemoryBarrier',None,C.c_uint)(0xFFFFFFFF)
  error=self.function('glGetError',C.c_uint)()
  assert error==0,f'OpenGL error 0x{error:X}'

 def close(self):
  for name in self.programs:self.function('glDeleteProgram',None,C.c_uint)(name)
  for label,values in (('Textures',self.textures),('Buffers',self.buffers)):
   if values:self.function('glDelete'+label,None,C.c_int,C.POINTER(C.c_uint))(len(values),(C.c_uint*len(values))(*values))
  self.make_current(self.display,None,None,None)
  self.native('eglDestroyContext',C.c_uint,C.c_void_p,C.c_void_p)(self.display,self.context)
  self.native('eglTerminate',C.c_uint,C.c_void_p)(self.display)
  if self._dll_directory is not None:
   self._dll_directory.close()

def execute(variants):
 gl=SoftwareGL()
 try:
  p={name:gl.compile(source) for name,source in variants.items()}
  w=h=64;dw=dh=32;lw=lh=16
  # Deterministic block texture makes an exact 4-pixel translation observable.
  field=[((x*73+y*151+x*y*29)%191+32)/255 for y in range(lh) for x in range(lw)]
  color=[c for y in range(h) for x in range(w) for c in [field[(y//4)*lw+x//4]]*4]
  picture=gl.texture(w,h,0x8058,4,color) # RGBA8
  depth_values=[(x+3*y)/(dw+3*dh) for y in range(dh) for x in range(dw)]
  depth=gl.texture(dw,dh,0x822E,1,depth_values) # R32F
  previous=gl.texture(lw,lh,0x881A,4,[0.]*(lw*lh*4))
  current=gl.texture(lw,lh,0x881A,4)
  coarse=gl.texture(lw,lh,0x822F,2)
  depth_out=gl.texture(w,h,0x822E,1)
  motion_out=gl.texture(w,h,0x822F,2)
  inputs=[picture,depth,previous,current,coarse];outputs=[current,coarse,depth_out,motion_out]
  constants=lambda warm,reverse=0,flags=0:struct.pack('<5If2I',w,h,warm,reverse,flags,1.,dw,dh)
  gl.run(p['Prepare'],inputs,outputs,constants(0),2,2)
  gl.run(p['Estimate'],inputs,outputs,constants(0),2,2)
  assert all(x==0 for x in gl.read(coarse)),'Warm-up produced invented temporal motion'
  prepared=gl.read(current)
  gl.upload(previous,prepared)
  moved=[c for y in range(h) for x in range(w) for c in [field[(y//4)*lw+max(0,x//4-1)]]*4]
  gl.upload(picture,moved)
  gl.run(p['Prepare'],inputs,outputs,constants(1),2,2)
  gl.run(p['Estimate'],inputs,outputs,constants(1),2,2)
  motion=gl.read(coarse)
  for y in range(3,lh-3):
   for x in range(4,lw-3):
    i=(y*lw+x)*2
    assert abs(motion[i]+4/w)<1e-5 and abs(motion[i+1])<1e-5,(x,y,motion[i:i+2])
  for flags in range(4):
   gl.run(p['Resolve'],inputs,outputs,constants(1,1,flags),8,8)
   actual=gl.read(depth_out)
   for y in range(h):
    for x in range(w):
     sx=min(((2*x+1)*dw)//(w*2),dw-1);sy=min(((2*y+1)*dh)//(h*2),dh-1)
     if flags&2:sy=dh-1-sy
     d=depth_values[sy*dw+sx]
     if flags&1:d=(math.exp(d*math.log(1.01))-1)/0.01
     expected=max(0,min(1,1-d))
     assert abs(actual[y*w+x]-expected)<2e-5,(flags,x,y,actual[y*w+x],expected)
  final=gl.read(motion_out)
  for y in range(12,52):
   for x in range(16,52):
    i=(y*w+x)*2
    assert abs(final[i]+4/w)<1e-5 and abs(final[i+1])<1e-5
  print('PASS: software GL '+gl.renderer+'; original three kernels compile/link and execute; warm-up zero motion, backward UV translation, scaled/reversed/log/vertical depth and full-resolution motion verified. No Windows/NR/display qualification.')
 finally:gl.close()

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--software-gl',action='store_true');args=parser.parse_args()
 variants=source_contract()
 if args.software_gl:execute(variants)
