// The OpenJPEG decode build ships no types
declare module '@cornerstonejs/codec-openjpeg/decodewasmjs' {
  const factory: (init?: Record<string, unknown>) => Promise<any>;
  export default factory;
}
