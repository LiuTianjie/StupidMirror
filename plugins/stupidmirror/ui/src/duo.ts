import { screenPoint, type ScreenMesh } from './mesh';

export type DuoPose = {
  model_id: string; angle: number; orientation: number; screen: number;
  frame_aspect_ratio: number; screen_ready: boolean;
};
export type DuoAsset = {
  id: string; vertex_count: number; joint_count: number; sample_count: number;
  positions: string; texcoords: string; joints: string; weights: string;
  indices: string; poses: string; bounds: string;
  parts: { offset: number; count: number; color: number[]; screen: number }[];
};
type Rig = {
  source: DuoAsset; positions: Float32Array; uv: Float32Array; joints: Uint16Array;
  weights: Float32Array; indices: Uint32Array; poses: Float32Array; bounds: Float32Array;
};
type Spring = { value: number; velocity: number };
const clamp = (v: number, min: number, max: number) => Math.min(max, Math.max(min, v));

// Same critically damped spring as the native display-link renderer. A target
// change preserves velocity; network replies never restart a CSS transition.
function advance(spring: Spring, target: number, dt: number) {
  const omega = 16, offset = spring.value - target, carry = spring.velocity + omega * offset;
  const decay = Math.exp(-omega * dt);
  spring.value = target + (offset + carry * dt) * decay;
  spring.velocity = (spring.velocity - omega * carry * dt) * decay;
  if (Math.abs(spring.value - target) < .015 && Math.abs(spring.velocity) < .15) {
    spring.value = target; spring.velocity = 0; return false;
  }
  return true;
}
function bytes(value: string) {
  const decoded = atob(value), result = new Uint8Array(decoded.length);
  for (let i = 0; i < decoded.length; i++) result[i] = decoded.charCodeAt(i);
  return result.buffer;
}
function decode(source: DuoAsset): Rig | undefined {
  try {
    if (!Number.isInteger(source.vertex_count) || source.vertex_count <= 0 || source.vertex_count > 500_000
        || !Number.isInteger(source.joint_count) || source.joint_count <= 0 || source.joint_count > 256
        || !Number.isInteger(source.sample_count) || source.sample_count < 2 || source.sample_count > 512) return;
    const rig: Rig = {source, positions:new Float32Array(bytes(source.positions)), uv:new Float32Array(bytes(source.texcoords)),
      joints:new Uint16Array(bytes(source.joints)), weights:new Float32Array(bytes(source.weights)),
      indices:new Uint32Array(bytes(source.indices)), poses:new Float32Array(bytes(source.poses)), bounds:new Float32Array(bytes(source.bounds))};
    const n = source.vertex_count;
    if (rig.positions.length !== n*3 || rig.uv.length !== n*2 || rig.joints.length !== n*8 || rig.weights.length !== n*8
        || rig.poses.length !== source.joint_count*source.sample_count*16 || rig.bounds.length !== source.sample_count*4
        || !rig.indices.every(i=>i<n) || !rig.joints.every(i=>i<source.joint_count)
        || !source.parts.every(p=>Number.isInteger(p.offset) && Number.isInteger(p.count) && p.offset>=0 && p.count>=0
          && p.count%3===0 && p.offset+p.count<=rig.indices.length && p.color.length===3 && p.color.every(Number.isFinite))) return;
    return rig;
  } catch { return; }
}
export function validDuoPose(pose: DuoPose | undefined): pose is DuoPose {
  return !!pose && typeof pose.model_id==='string' && Number.isFinite(pose.angle) && pose.angle>=0 && pose.angle<=180
    && Number.isFinite(pose.orientation) && (pose.screen===1 || pose.screen===2)
    && Number.isFinite(pose.frame_aspect_ratio) && pose.frame_aspect_ratio>0;
}
function uv(u: number, v: number, orientation: number) {
  switch (Math.round(orientation)%360) {
    case 90: return [1-v,u]; case 180: return [1-u,1-v]; case 270: return [v,1-u]; default: return [u,v];
  }
}
function transform(angle: number, orientation: number) {
  const t = clamp(angle/130,0,1), cover=-Math.PI/2*(1-t*t*(3-2*t));
  const ca=Math.cos(cover), sa=Math.sin(cover), c=Math.cos(orientation*Math.PI/180), s=Math.sin(orientation*Math.PI/180);
  return new Float32Array([c*ca,sa,s*ca,0, -c*sa,ca,-s*sa,0, -s,0,c,0, 0,0,0,1]);
}
function multiply(m: Float32Array, x:number, y:number, z:number, w=1) {
  return [m[0]*x+m[4]*y+m[8]*z+m[12]*w, m[1]*x+m[5]*y+m[9]*z+m[13]*w,
    m[2]*x+m[6]*y+m[10]*z+m[14]*w, m[3]*x+m[7]*y+m[11]*z+m[15]*w];
}

export function createDuoPreview(canvas: HTMLCanvasElement) {
  let gl: WebGL2RenderingContext | null | undefined, program: WebGLProgram | undefined, texture: WebGLTexture | null;
  let rig: Rig | undefined, buffers: WebGLBuffer[] = [], boneMatrices = new Float32Array(0);
  let target: DuoPose | undefined, confirmed: DuoPose | undefined, pendingAngle: number | undefined;
  let hinge: Spring={value:180,velocity:0}, rotation: Spring={value:0,velocity:0}, rotationTarget=0;
  let enabled=false, moving=false, matchingFrame=false, opacity=0, width=1, height=1, lastTick=0;
  let lastSource: HTMLImageElement | HTMLVideoElement | undefined, lastFrame: string | number | undefined;
  let raf: number | undefined, hitMesh: ScreenMesh | undefined, hitKey='';
  let locations: Record<string,WebGLUniformLocation|null>={};
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');

  function initialize(asset: DuoAsset) {
    if (rig?.source.id===asset.id && program) return true;
    const decoded=decode(asset);
    if (!decoded) return false;
    rig=decoded;
    if (gl===undefined) gl=canvas.getContext('webgl2',{alpha:true,antialias:true,premultipliedAlpha:true});
    if (!gl || gl.getParameter(gl.MAX_VERTEX_UNIFORM_VECTORS)<asset.joint_count*4+12) return false;
    const shader=(kind:number, text:string) => {
      const result=gl!.createShader(kind)!;
      gl!.shaderSource(result,text); gl!.compileShader(result);
      if (!gl!.getShaderParameter(result,gl!.COMPILE_STATUS)) {gl!.deleteShader(result);return;}
      return result;
    };
    const vertex=shader(gl.VERTEX_SHADER, '#version 300 es\n'+
      'in vec3 position; in vec2 uv; in vec4 joints; in vec4 weights; in vec4 joints2; in vec4 weights2; uniform mat4 bones['+asset.joint_count+'];'+
      'uniform mat4 model; uniform mat4 projection; out vec2 pixel;'+
      'void main(){mat4 skin=bones[int(joints.x)]*weights.x+bones[int(joints.y)]*weights.y+bones[int(joints.z)]*weights.z+bones[int(joints.w)]*weights.w+bones[int(joints2.x)]*weights2.x+bones[int(joints2.y)]*weights2.y+bones[int(joints2.z)]*weights2.z+bones[int(joints2.w)]*weights2.w;'+
      'vec4 p=model*skin*vec4(position,1.0);gl_Position=projection*vec4(p.x,-p.z,p.y-60.0,1.0);pixel=uv;}');
    const fragment=shader(gl.FRAGMENT_SHADER, '#version 300 es\nprecision mediump float;'+
      'in vec2 pixel; uniform sampler2D frame; uniform vec3 color; uniform float screenOpacity; uniform int quarterTurn; out vec4 result;'+
      'void main(){vec2 p=pixel;if(quarterTurn==1)p=vec2(1.0-p.y,p.x);else if(quarterTurn==2)p=1.0-p;else if(quarterTurn==3)p=vec2(p.y,1.0-p.x);'+
      'result=vec4(mix(color,texture(frame,p).rgb,screenOpacity),1.0);}');
    if (!vertex || !fragment) return false;
    const next=gl.createProgram()!;
    gl.attachShader(next,vertex);gl.attachShader(next,fragment);gl.linkProgram(next);gl.deleteShader(vertex);gl.deleteShader(fragment);
    if (!gl.getProgramParameter(next,gl.LINK_STATUS)) {gl.deleteProgram(next);return false;}
    if (program) gl.deleteProgram(program);
    buffers.forEach(b=>gl!.deleteBuffer(b)); buffers=[];
    program=next;rig=decoded;gl.useProgram(program);
    for(const [name,data,components,type,stride,offset] of [
      ['position',rig.positions,3,gl.FLOAT,0,0],['uv',rig.uv,2,gl.FLOAT,0,0],
      ['joints',rig.joints,4,gl.UNSIGNED_SHORT,16,0],['weights',rig.weights,4,gl.FLOAT,32,0],
      ['joints2',rig.joints,4,gl.UNSIGNED_SHORT,16,8],['weights2',rig.weights,4,gl.FLOAT,32,16],
    ] as const) {
      const buffer=gl.createBuffer()!;buffers.push(buffer);gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);
      const location=gl.getAttribLocation(program,name);gl.enableVertexAttribArray(location);gl.vertexAttribPointer(location,components,type,false,stride,offset);
    }
    const indices=gl.createBuffer()!;buffers.push(indices);gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,indices);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,rig.indices,gl.STATIC_DRAW);
    for(const name of ['bones[0]','model','projection','color','screenOpacity','quarterTurn']) locations[name]=gl.getUniformLocation(program,name);
    if(texture)gl.deleteTexture(texture);
    texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));
    gl.enable(gl.DEPTH_TEST);gl.enable(gl.CULL_FACE);gl.clearColor(0,0,0,0);
    boneMatrices=new Float32Array(asset.joint_count*16);
    return true;
  }
  function applyPose(pose: DuoPose) {
    if(!target){hinge={value:pose.angle,velocity:0};rotation={value:pose.orientation,velocity:0};}
    if(!target || target.angle!==pose.angle || target.orientation!==pose.orientation || target.screen!==pose.screen){
      if(target?.screen!==pose.screen || target?.orientation!==pose.orientation){matchingFrame=false;opacity=0;}
      hitMesh=undefined;
      let delta=(pose.orientation-rotation.value)%360;
      if(delta>180)delta-=360;if(delta< -180)delta+=360;
      rotationTarget=rotation.value+delta;
    }
    target=pose;
    if(reduced.matches){hinge={value:pose.angle,velocity:0};rotation={value:rotationTarget,velocity:0};}
    moving=Math.abs(hinge.value-pose.angle)>.015 || Math.abs(rotation.value-rotationTarget)>.015;
    wake();
  }
  function requestedPose(pose:DuoPose) {
    if(pendingAngle===undefined)return pose;
    const screen=pendingAngle===0?2:1,portraitAspect=screen===1?2007/2853:1398/2034;
    const sideways=(pose.orientation+(screen===1?90:0))%180===90;
    return {...pose,angle:pendingAngle,screen,frame_aspect_ratio:sideways?1/portraitAspect:portraitAspect,screen_ready:false};
  }
  function configure(pose?:DuoPose, asset?:DuoAsset, w=1,h=1) {
    if(asset && rig?.source.id!==asset.id && !initialize(asset)) return false;
    enabled=!!pose && !!rig && pose.model_id===rig.source.id && !!program;
    canvas.hidden=!enabled;
    if(!enabled || !pose || !gl)return false;
    width=Math.max(1,w);height=Math.max(1,h);
    const ratio=Math.min(window.devicePixelRatio||1,2), pw=Math.round(width*ratio),ph=Math.round(height*ratio);
    if(canvas.width!==pw || canvas.height!==ph){canvas.width=pw;canvas.height=ph;hitMesh=undefined;}
    gl.viewport(0,0,pw,ph);
    confirmed=pose;
    applyPose(requestedPose(pose));
    return true;
  }
  function projection(angle:number,orientation:number) {
    const r=rig!,step=clamp(angle,0,180)/180*(r.source.sample_count-1),lo=Math.floor(step),hi=Math.min(lo+1,r.source.sample_count-1),t=step-lo;
    const b=[0,1,2,3].map(i=>r.bounds[lo*4+i]+(r.bounds[hi*4+i]-r.bounds[lo*4+i])*t);
    const c=Math.cos(orientation*Math.PI/180),s=Math.sin(orientation*Math.PI/180);
    const corners=[[b[0],b[1]],[b[2],b[1]],[b[0],b[3]],[b[2],b[3]]].map(([x,y])=>[x*c-y*s,x*s+y*c]);
    const xs=corners.map(p=>p[0]),ys=corners.map(p=>p[1]),minx=Math.min(...xs),maxx=Math.max(...xs),miny=Math.min(...ys),maxy=Math.max(...ys);
    const hh=Math.max(maxy-miny,(maxx-minx)/(width/height))/2/.975,hw=hh*width/height,near=.1,far=100;
    return new Float32Array([60/hw,0,0,0, 0,60/hh,0,0, (minx+maxx)/2/hw,-(miny+maxy)/2/hh,-(far+near)/(far-near),-1, 0,0,-2*far*near/(far-near),0]);
  }
  function sample(angle:number) {
    const r=rig!,step=clamp(angle,0,180)/180*(r.source.sample_count-1),lo=Math.floor(step),hi=Math.min(lo+1,r.source.sample_count-1),t=step-lo,n=boneMatrices.length;
    for(let i=0;i<n;i++)boneMatrices[i]=r.poses[lo*n+i]+(r.poses[hi*n+i]-r.poses[lo*n+i])*t;
  }
  function render(now:number) {
    raf=undefined;
    if(!enabled || !gl || !target || !rig || document.hidden)return;
    const dt=clamp((now-lastTick)/1000,0,.05);lastTick=now;
    const folding=advance(hinge,target.angle,dt),rotating=advance(rotation,rotationTarget,dt);moving=folding||rotating;
    // Keep a shared inner-screen frame through a fold. A new display frame
    // can appear as soon as it arrives, without waiting for the spring or HID.
    const reveal=matchingFrame;
    opacity=reveal ? Math.min(1,opacity+dt/.06) : 0;
    const blur=reduced.matches?0:Math.min(1.2,Math.abs(hinge.velocity)/700);
    canvas.style.filter=blur>.01?`blur(${blur.toFixed(2)}px)`:'none';
    sample(hinge.value);
    gl.uniformMatrix4fv(locations['bones[0]'],false,boneMatrices);
    gl.uniformMatrix4fv(locations.model,false,transform(hinge.value,rotation.value));
    gl.uniformMatrix4fv(locations.projection,false,projection(hinge.value,rotation.value));
    gl.uniform1i(locations.quarterTurn,Math.round(target.orientation/90)%4);
    gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
    for(const part of rig.source.parts){
      gl.uniform3fv(locations.color,part.color);
      gl.uniform1f(locations.screenOpacity,part.screen===target.screen ? opacity : 0);
      gl.drawElements(gl.TRIANGLES,part.count,gl.UNSIGNED_INT,part.offset*4);
    }
    canvas.dataset.hinge=hinge.value.toFixed(2);
    canvas.dataset.moving=String(moving);
    canvas.dataset.motionBlur=blur.toFixed(2);
    canvas.dataset.screenVisible=String(reveal && opacity>=1);
    if(moving || (reveal && opacity<1))wake(true);
  }
  function wake(continuing=false) {
    if(raf!==undefined || !enabled || document.hidden)return;
    if(!continuing)lastTick=performance.now();
    raf=requestAnimationFrame(render);
  }
  function draw(source:HTMLImageElement|HTMLVideoElement) {
    if(!enabled || !gl || !target || document.hidden)return;
    const w=source instanceof HTMLVideoElement ? source.videoWidth : source.naturalWidth;
    const h=source instanceof HTMLVideoElement ? source.videoHeight : source.naturalHeight;
    if(!w || !h || Math.abs(w/h/target.frame_aspect_ratio-1)>.02)return;
    const frame=source instanceof HTMLVideoElement ? source.currentTime : source.currentSrc||source.src;
    if(source===lastSource && frame===lastFrame)return;
    try{
      gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,source);
      lastSource=source;lastFrame=frame;matchingFrame=true;wake();
    }catch{}
  }
  function point(p:{x:number;y:number},clamped:boolean) {
    if(!target || !rig || moving || !matchingFrame || !target.screen_ready || pendingAngle!==undefined || opacity<.99)return;
    const key=[target.angle,target.orientation,target.screen,width,height].join('|');
    if(!hitMesh || hitKey!==key){
      sample(target.angle);
      const model=transform(target.angle,target.orientation),project=projection(target.angle,target.orientation),mapped=new Map<number,number>();
      hitMesh={vertices:[],triangles:[],frame_aspect_ratio:target.frame_aspect_ratio};hitKey=key;
      for(const part of rig.source.parts)if(part.screen===target.screen){
        for(let offset=part.offset;offset<part.offset+part.count;offset++){
          const i=rig.indices[offset],existing=mapped.get(i);
          if(existing!==undefined){hitMesh.triangles.push(existing);continue;}
          const p=[0,0,0,0],x=rig.positions[i*3],y=rig.positions[i*3+1],z=rig.positions[i*3+2];
          for(let j=0;j<8;j++){
            const weight=rig.weights[i*8+j];if(!weight)continue;
            const bone=boneMatrices.subarray(rig.joints[i*8+j]*16,rig.joints[i*8+j]*16+16),v=multiply(bone,x,y,z);
            for(let k=0;k<4;k++)p[k]+=v[k]*weight;
          }
          const world=multiply(model,p[0],p[1],p[2]),clip=multiply(project,world[0],-world[2],world[1]-60),tex=uv(rig.uv[i*2],rig.uv[i*2+1],target.orientation);
          mapped.set(i,hitMesh.vertices.length);hitMesh.triangles.push(hitMesh.vertices.length);
          hitMesh.vertices.push([(clip[0]/clip[3]+1)/2,(1-clip[1]/clip[3])/2,tex[0],tex[1]]);
        }
      }
    }
    return screenPoint(hitMesh,p,clamped);
  }
  function beginPosture(angle:number) {
    if(!target)return;
    pendingAngle=angle;lastTick=performance.now();
    applyPose(requestedPose(target));
  }
  function finishPosture() {
    pendingAngle=undefined;
    if(confirmed)applyPose(confirmed);
  }
  function clear() {
    enabled=false;canvas.hidden=true;pendingAngle=undefined;target=confirmed=undefined;matchingFrame=false;opacity=0;hitMesh=undefined;
    lastSource=undefined;lastFrame=undefined;canvas.style.filter='none';
    if(raf!==undefined)cancelAnimationFrame(raf);raf=undefined;
    if(gl){gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array([0,0,0,255]));}
  }
  function dispose(){clear();if(gl){buffers.forEach(b=>gl!.deleteBuffer(b));if(program)gl.deleteProgram(program);gl.deleteTexture(texture);}rig=undefined;}
  return {configure,draw,point,clear,dispose,beginPosture,finishPosture,
    get active(){return enabled;},get transitioning(){return moving || pendingAngle!==undefined;},get modelID(){return rig?.source.id;}};
}
