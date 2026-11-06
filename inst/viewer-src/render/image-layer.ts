// One image as a deck.gl layer, for the main view and the registration pane.
// Single-channel images add up: each draws its colour scaled by intensity on
// top of the others, as the channels of one fluorescence image would. RGB
// images (brightfield) blend normally and draw first: added, their white
// background would wash out everything over it
import { MultiscaleImageLayer } from '@vivjs/layers';
import type { LensImage } from '../data/images.ts';
import type { ImageVis } from '../core/store.ts';

const ADDITIVE = {
  blend: true,
  blendColorOperation: 'add', blendColorSrcFactor: 'src-alpha', blendColorDstFactor: 'one',
  blendAlphaOperation: 'add', blendAlphaSrcFactor: 'one', blendAlphaDstFactor: 'one',
};
const SELECTION = [{ t: 0, c: 0, z: 0 }];

export function imageLayer(id: string, img: LensImage, v: ImageVis | undefined, modelMatrix: unknown, opacity: number) {
  if (img.rgb) {
    return new MultiscaleImageLayer({
      id, loader: img.levels, selections: SELECTION, modelMatrix, opacity, pickable: false,
    } as any);
  }
  return new MultiscaleImageLayer({
    id, loader: img.levels, selections: SELECTION,
    colors: [v?.color ?? [255, 255, 255]], contrastLimits: [v?.contrast ?? img.contrast], channelsVisible: [true],
    modelMatrix, opacity,
    // No low-resolution backdrop and no parent tiles under loaded ones:
    // with additive blending, overlaps would draw twice as bright
    excludeBackground: true, refinementStrategy: 'no-overlap',
    parameters: ADDITIVE,
    pickable: false,
  } as any);
}
