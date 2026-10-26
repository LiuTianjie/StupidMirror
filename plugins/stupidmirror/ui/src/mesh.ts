export type ScreenMesh = { vertices: number[][]; triangles: number[]; frame_aspect_ratio: number };
type Point = { x: number; y: number };

// The server projects Device Hub's articulated display mesh. Use those exact
// triangles for both pixels and input, including the curved hinge and corners.
export function screenPoint(mesh: ScreenMesh, point: Point, clamped = false): Point | undefined {
  let nearest: Point | undefined, distance = Infinity;
  for (let i = 0; i + 2 < mesh.triangles.length; i += 3) {
    const [a,b,c] = mesh.triangles.slice(i,i+3).map(index => mesh.vertices[index]);
    const determinant = (b[1]-c[1])*(a[0]-c[0]) + (c[0]-b[0])*(a[1]-c[1]);
    if (Math.abs(determinant) < 1e-12) continue;
    const u = ((b[1]-c[1])*(point.x-c[0])+(c[0]-b[0])*(point.y-c[1]))/determinant;
    const v = ((c[1]-a[1])*(point.x-c[0])+(a[0]-c[0])*(point.y-c[1]))/determinant;
    const w = 1-u-v;
    if (u >= -1e-6 && v >= -1e-6 && w >= -1e-6) return {
      x: Math.max(0,Math.min(1,u*a[2]+v*b[2]+w*c[2])), y: Math.max(0,Math.min(1,u*a[3]+v*b[3]+w*c[3])),
    };
    if (clamped) for (const [start,end] of [[a,b],[b,c],[c,a]]) {
      const dx=end[0]-start[0], dy=end[1]-start[1], length=dx*dx+dy*dy;
      const t=length > 0 ? Math.max(0,Math.min(1,((point.x-start[0])*dx+(point.y-start[1])*dy)/length)) : 0;
      const d = (start[0]+t*dx-point.x)**2 + (start[1]+t*dy-point.y)**2;
      if (d < distance) { distance = d; nearest = {x:start[2]+t*(end[2]-start[2]),y:start[3]+t*(end[3]-start[3])}; }
    }
  }
  return clamped ? nearest : undefined;
}

export function validMesh(value: ScreenMesh | undefined): value is ScreenMesh {
  return !!value && Number.isFinite(value.frame_aspect_ratio) && value.frame_aspect_ratio > 0
    && Array.isArray(value.vertices) && value.vertices.length > 2 && value.vertices.length < 65536
    && value.vertices.every(v => Array.isArray(v) && v.length === 4 && v.every(Number.isFinite))
    && Array.isArray(value.triangles) && value.triangles.length > 2 && value.triangles.length % 3 === 0
    && value.triangles.every(i => Number.isInteger(i) && i >= 0 && i < value.vertices.length);
}

