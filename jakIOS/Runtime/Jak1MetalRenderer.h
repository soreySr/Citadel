#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif
/// Records that GS VRAM block `tbp` now holds PC texture `comboId` (tpage id << 16 | index),
/// as OpenGOAL's TexturePool::handle_upload_now does. Thread-safe; called from the game thread.
void Jak1TexturePoolSetVramSlot(uint32_t tbp, uint32_t comboId);
/// __pc-texture-relocate (TexturePool::relocate): the texture at VRAM block `sourceTbp` was
/// moved to `destinationTbp`. Format 44 (PSMT4HH) copies are tracked separately, and are found
/// by looking up `destinationTbp | 0x8000`. Thread-safe; called from the game thread.
void Jak1TexturePoolRelocate(uint32_t destinationTbp, uint32_t sourceTbp, uint32_t format);
/// Saves the current VRAM layout as snapshot `slot` (0..1). Uploads are applied for the whole
/// frame before drawing, so passes that sample VRAM mid-chain (sky blend, after its level's
/// alpha tpage upload) must look up in a snapshot taken at their bucket. Render thread only.
void Jak1TexturePoolSaveSnapshot(int slot);
/// Clears snapshot `slot` (its bucket was not reached this frame). Render thread only.
void Jak1TexturePoolClearSnapshot(int slot);
/// While replaying a frame's upload packets, records each VRAM write with the packet's trace
/// offset (set before each packet) so passes can sample VRAM as it was at their bucket
/// (Jak1TexturePoolLookupAtTraceOffset). End publishes the journal. Render thread only.
void Jak1TexturePoolBeginTraceJournal(void);
void Jak1TexturePoolSetTraceJournalOffset(uint32_t traceOffset);
void Jak1TexturePoolEndTraceJournal(void);
/// Game-area size requested by OpenGOAL's pc-set-letterbox (window pixels). The renderer keeps
/// this aspect ratio, centered in the drawable; 0 x 0 fills the whole drawable. Thread-safe.
void Jak1RendererSetLetterbox(int32_t width, int32_t height);
/// The last pc-set-letterbox size (0 x 0 = fill the drawable). Thread-safe.
void Jak1RendererGetLetterbox(int32_t *width, int32_t *height);
/// Driveable Boat summon (pc/ios/ios-boat-summon.gc): while `active`, every fishermans-boat Merc model is drawn
/// alpha blended with alpha scaled by `alpha` (0..1) and its colour mixed toward a cyan glow by `glow` (0..1).
/// The host mirrors GOAL *ios-boat-summon-fade*. Thread-safe.
void Jak1RendererSetBoatFade(bool active, float alpha, float glow);
#ifdef __cplusplus
}
#endif

@interface Jak1MetalRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// uint32 trace offset per Jak 1 bucket (UINT32_MAX = not reached) for the next frame's DMA trace.
- (void)setDMABucketTraceOffsets:(nullable NSData *)offsets;

/// GOAL memory referenced by the next frame's Merc draws (bone matrices, update-verts fragments),
/// copied at chain submission (SnapshotMercMemory): u32 range count, 12 pad bytes, per range
/// {u32 address, u32 length, u32 data offset, u32 pad} sorted and non-overlapping, then the data.
/// The renderer keeps a reference to `snapshot` until the next call.
- (void)setMercMemorySnapshot:(nullable NSData *)snapshot;

/// Encodes and presents one frame. Safe to call off the main thread (one frame at a time); the
/// pass descriptor and drawable are acquired from the MTKView on the main thread by the caller.
- (void)renderFrameWithPassDescriptor:(MTLRenderPassDescriptor *)passDesc
                             drawable:(id<CAMetalDrawable>)drawable
                         commandQueue:(id<MTLCommandQueue>)commandQueue
                dmaBuffer:(nullable NSData *)dmaBuffer
            textureBuffer:(nullable id<MTLBuffer>)textureBuffer
                goalMemory:(nullable const void *)goalMemory
            goalMemorySize:(NSUInteger)goalMemorySize
             displayAlpha:(double)displayAlpha
             contentReady:(BOOL)contentReady;

@end

NS_ASSUME_NONNULL_END
