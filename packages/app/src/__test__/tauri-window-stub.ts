const mockWindow = {
  close: vi.fn().mockResolvedValue(undefined),
};

export function getCurrentWindow() {
  return mockWindow;
}
