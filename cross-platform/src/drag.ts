export interface Point { x: number; y: number }
export interface Rect extends Point { width: number; height: number }
export function position(origin: Point, start: Point, current: Point): Point {
  return { x: Math.round(origin.x + current.x - start.x), y: Math.round(origin.y + current.y - start.y) };
}
export function contains(rect: Rect, point: Point): boolean {
  return point.x >= rect.x && point.y >= rect.y && point.x < rect.x + rect.width && point.y < rect.y + rect.height;
}
export function validRegions(value: unknown): value is Rect[] {
  return Array.isArray(value) && value.length <= 3 && value.every(r => r && typeof r === 'object' &&
    ['x', 'y', 'width', 'height'].every(k => Number.isFinite(r[k])) && r.x >= 0 && r.y >= 0 &&
    r.width > 0 && r.height > 0 && r.x + r.width <= 420 && r.y + r.height <= 700);
}
