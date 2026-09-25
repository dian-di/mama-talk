export { cn } from 'cn'

export function uuid() {
  return (Math.random() + 1).toString(36).substring(4)
}