//
// ORGMInputUnit.m
//
// Copyright (c) 2012 ap4y (lod@pisem.net)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ORGMInputUnit.h"

#import "ORGMPluginManager.h"

@interface ORGMInputUnit () <ORGMSourceDelegate> {
    int bytesPerFrame;
    BOOL _shouldSeek;
    long seekFrame;
    BOOL _processing;
    NSDictionary *_decoderMetadata;
    NSMutableDictionary *_inputUnitMetadata;
}

@property (strong, nonatomic) NSMutableData *data;
@property (strong, nonatomic) id<ORGMSource> source;
@property (strong, nonatomic) id<ORGMDecoder> decoder;
@property (assign, nonatomic) BOOL endOfInput;
@property (strong, nonatomic) NSURL *url;
@property (strong, nonatomic) dispatch_queue_t lock_queue;
@property (assign, nonatomic) void *inputBuffer;

@end

@implementation ORGMInputUnit

- (instancetype)init {
    self = [super init];
    if (self) {
        self.lock_queue = dispatch_queue_create("com.origami.lock",DISPATCH_QUEUE_SERIAL);
        self.data = [[NSMutableData alloc] init];
        self.inputBuffer = malloc(CHUNK_SIZE);
        _endOfInput = NO;
        _processing = NO;
    }
    return self;
}

- (void)dealloc {
    self.inputUnitDelegate = nil;
    [self close];
    free(self.inputBuffer);
    self.source.sourceDelegate = nil;
    self.url = nil;
}

- (BOOL)isProcessing{
    return _processing;
}

#pragma mark - public

- (BOOL)openWithUrl:(NSURL *)url {
    self.url = url;
    self.source = [[ORGMPluginManager sharedManager] sourceForURL:url error:nil];
    self.source.sourceDelegate = self;
    if (!self.source || ![self.source open:url]){
        return NO;
    }
    self.decoder = [[ORGMPluginManager sharedManager] decoderForSource:self.source error:nil];
    if (!self.decoder || ![self.decoder open:self.source]){
        return NO;
    }
    int bitsPerSample = [[_decoder.properties objectForKey:@"bitsPerSample"] intValue];
	int channels = [[_decoder.properties objectForKey:@"channels"] intValue];
    bytesPerFrame = (bitsPerSample/8) * channels;
    return YES;
}

- (NSURL *)currentURL{
    return self.url;
}

- (float)preloadProgress{
    long size = [self.source size];
    long current = [self.source preloadSize];
    if(size!=0){
        return (float)current/(float)size;
    }
    return 0.0;
}

- (void)close {
    [_source close];
    [_decoder close];
}

- (void)process {
    
    if(self.isCancelled){
        return;
    }
    
    _processing = YES;
    
    int amountInBuffer = 0;
    int framesRead = 0;

    do {
        
        if(self.isCancelled){
            _processing = NO;
            return;
        }
        
        if (_data.length >= BUFFER_SIZE) {
            framesRead = 1;
            break;
        }

        if (_shouldSeek) {
            [_decoder seek:seekFrame];
            _shouldSeek = NO;
        }
        int framesToRead = 0;
        if(bytesPerFrame>0){
            framesToRead = CHUNK_SIZE/bytesPerFrame;
        }
        framesRead = [_decoder readAudio:self.inputBuffer frames:framesToRead];
        amountInBuffer = (framesRead * bytesPerFrame);

        __weak typeof (self) weakSelf = self;
        dispatch_sync(self.lock_queue, ^{
            [weakSelf.data appendBytes:weakSelf.inputBuffer length:amountInBuffer];
        });
    } while (framesRead > 0 && self.isCancelled==NO);

    if (framesRead <= 0 && self.isCancelled==NO) {
        [self setEndOfInput:YES];
        if([self.inputUnitDelegate respondsToSelector:@selector(inputUnitDidEndOfInput:)]){
            [self.inputUnitDelegate inputUnitDidEndOfInput:self];
        }
    }

    _processing = NO;
}

- (double)framesCount {
    NSNumber *frames = [_decoder.properties objectForKey:@"totalFrames"];
    return [frames doubleValue];
}

- (void)seek:(double)time withDataFlush:(BOOL)flush {
    if (flush) {
         __weak typeof (self) weakSelf = self;
        dispatch_sync(self.lock_queue, ^{
            weakSelf.data = [[NSMutableData alloc] init];
        });
    }
    seekFrame = time * [[_decoder.properties objectForKey:@"sampleRate"] floatValue];
    _shouldSeek = YES;
}

- (void)seek:(double)time {
    [self seek:time withDataFlush:NO];
}

- (AudioStreamBasicDescription)format {
    return propertiesToASBD(_decoder.properties);
}

- (NSDictionary *)decoderMetadata{
    if(_decoderMetadata==nil ){
        @try {
            NSDictionary *meta = [self.decoder metadata];
            if([meta count]>0){
                _decoderMetadata = [meta copy];
            }
        } @catch (NSException *exception) {}
    }
    return _decoderMetadata;
}

- (NSMutableDictionary *)inputUnitMetadata{
    if(_inputUnitMetadata==nil && self.decoderMetadata){
        _inputUnitMetadata = [[NSMutableDictionary alloc] init];
        @try {
            NSDictionary *decoderMetadata = self.decoderMetadata;
            if(decoderMetadata.count>0){
                [_inputUnitMetadata addEntriesFromDictionary:decoderMetadata];
            }
        } @catch (NSException *exception) {
            _inputUnitMetadata = nil;
        }
    }
    return _inputUnitMetadata;
}

- (NSDictionary *)metadata {
    NSMutableDictionary *inputUnitMetadata = [self inputUnitMetadata];
    if(inputUnitMetadata){
        if(fabs(self.format.mSampleRate)>FLT_EPSILON){
            double trackDuration = self.framesCount/self.format.mSampleRate;
            [inputUnitMetadata setObject:@(trackDuration) forKey:@"duration"];
        }
    }
    return inputUnitMetadata;
}

- (int)shiftBytes:(NSUInteger)amount buffer:(void *)buffer {
    int bytesToRead = (int)MIN(amount, _data.length);
     __weak typeof (self) weakSelf = self;
    dispatch_sync(self.lock_queue, ^{
        memcpy(buffer, weakSelf.data.bytes, bytesToRead);
        [weakSelf.data replaceBytesInRange:NSMakeRange(0, bytesToRead) withBytes:NULL length:0];
    });
    return bytesToRead;
}

#pragma mark - private

- (void)sourceDidReceiveData:(id<ORGMSource>)source{
    if(source==self.source && [self.inputUnitDelegate respondsToSelector:@selector(inputUnit:didChangePreloadProgress:)]){
        [self.inputUnitDelegate inputUnit:self didChangePreloadProgress:self.preloadProgress];
    }
}

- (void)source:(id<ORGMSource>)source didFailWithError:(NSError *)error{
    if(source==self.source && [self.inputUnitDelegate respondsToSelector:@selector(inputUnit:didFailWithError:)]){
        [self.inputUnitDelegate inputUnit:self didFailWithError:error];
    }
}

@end
