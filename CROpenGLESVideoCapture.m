//
//  CROpenGLESVideoCapture.m
//  Unity-iPhone
//
//  Created by Dmitry Utenkov on 19.02.13.
//
//

#import "CROpenGLESVideoCapture.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import <AVFoundation/AVFoundation.h>
#import "ShaderUtilities.h"
#import "CRAudioWriter.h"
#import <CoreMedia/CoreMedia.h>

enum {
    POSITION_ATTRIBUTE,
    TEXTURE_COORDINATE_ATTRIBUTE,
    NUM_ATTRIBUTES
};

// Uniform index.
enum {
    UNIFORM_TEXTURE,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

@interface CROpenGLESVideoCapture () {
    CVOpenGLESTextureRef        renderTexture;
    CVPixelBufferRef            cvPixelBuffer;
    CMTime                      frameTime;
    GLuint                      passThroughProgram;
    CVOpenGLESTextureCacheRef   videoTextureCache;
    GLuint                      depthBuffer;
    CMBufferQueueRef            previewBufferQueue; 
    GLuint                      _positionVBO;
    GLuint                      _texcoordVBO;
    GLuint                      _indexVBO;
}

@property (nonatomic, assign)   BOOL                                    isCapturing;
@property (nonatomic, retain)   NSURL                                   *outputVideoFileURL;
@property (nonatomic, retain)   NSURL                                   *outputAudioFileURL;
@property (nonatomic, retain)   NSURL                                   *exportedVideoURL;
@property (nonatomic, retain)   AVAssetWriter                           *writer;
@property (nonatomic, retain)   AVAssetWriterInput                      *writerInput;
@property (nonatomic, retain)   AVAssetWriterInputPixelBufferAdaptor    *assetWriterPixelBufferAdaptor;
@property (nonatomic, retain)   CRAudioWriter                             *audioWriter;
@property (nonatomic, assign)   CFTimeInterval                          previousTimestamp;

@end

@implementation CROpenGLESVideoCapture

- (void)dealloc {
    [_outputVideoFileURL release];
    [_outputAudioFileURL release];
    [_exportedVideoURL release];
    [_writer release];
    [_writerInput release];
    [_assetWriterPixelBufferAdaptor release];
    [_audioWriter release];
    [super dealloc];
}

+ (id)sharedInstance {
    static dispatch_once_t once;
    static id sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (id)init {
    if (self = [super init]) {
        [self compileShadersForTextureDrawing];
        
        NSString *videoFilePath = [NSString stringWithFormat:@"%@/Documents/movie.m4v", NSHomeDirectory()];
        [self setOutputVideoFileURL:[NSURL fileURLWithPath:videoFilePath]];
        
        NSString *audioFilePath = [NSString stringWithFormat:@"%@/Documents/sound.m4a", NSHomeDirectory()];
        [self setOutputAudioFileURL:[NSURL fileURLWithPath:audioFilePath]];
        
        NSString *exportPath = [NSString stringWithFormat:@"%@/Documents/export.mov", NSHomeDirectory()];
        [self setExportedVideoURL:[NSURL fileURLWithPath:exportPath]];
    }
    return self;
}

#pragma mark - Capturing

- (void)startCapturing {
    [self setupAssetWriter];
    [[self writer] startWriting];
    [[self writer] startSessionAtSourceTime:CMTimeMake(0, 1000)];
    
    // Setting up buffer for rendering to texture should be done after starting session
    // because pixelBufferPool returns nil before it
    [self initRenderBuffer];
    
    [[self audioWriter] startRecording];
    [self setIsCapturing:YES];
    _previousTimestamp = CFAbsoluteTimeGetCurrent();
}

- (void)endCapturing {
    
    [self setIsCapturing:NO];
    CMBufferQueueReset(previewBufferQueue);
    
    [[self audioWriter] stopRecording];
    
    [[self writerInput] markAsFinished];
    [[self writer] endSessionAtSourceTime:frameTime];
    
    void (^SavingToLibraryBlock)()  = ^{
        [self mergeVideo:[self outputVideoFileURL] withAudio:[self outputAudioFileURL]];
    };
    
    // iOS 5 compatibility
    if ([[self writer] respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
        [[self writer] finishWritingWithCompletionHandler:SavingToLibraryBlock];
    } else {
        [[self writer] finishWriting];
        SavingToLibraryBlock();
    }
}

- (void)newFrameReady {
    if (![[self writerInput] isReadyForMoreMediaData]) {
        return;
    }
    
    // Wait for rendering finish
    //glFinish();
    
    // Enqueue video frame for asset writer
    OSStatus err = CMBufferQueueEnqueue(previewBufferQueue, cvPixelBuffer);
    if ( !err ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CVPixelBufferRef sbuf = (CVPixelBufferRef)CMBufferQueueDequeueAndRetain(previewBufferQueue);
            if (sbuf) {
                // Appending rendered frame to output video file
                if([[self assetWriterPixelBufferAdaptor] appendPixelBuffer:sbuf
                                                      withPresentationTime:frameTime] == NO)
                {
                    NSLog(@"Problem appending pixel buffer at time: %lld", frameTime.value);
                }
                else
                {
                    // Calculation of time for frame rendering
                    CFTimeInterval currentTimestamp = CFAbsoluteTimeGetCurrent();
                    CFTimeInterval frameDuration = currentTimestamp - _previousTimestamp;
                    _previousTimestamp = currentTimestamp;
                    
                    // CFTimeInterval represented in double (seconds)
                    // For milliseconds it should be multiplied by 1000
                    // Round needs for video/audio synchronization
                    frameTime.value += lroundf(frameDuration * 1000.0);
                }
                CFRelease(sbuf);
            }
        });
    }
    
    [self showRenderTextureOnScreen];
}

#pragma mark - Frame rendering

- (void)initRenderBuffer {
    // Create framebuffer
    glGenFramebuffers(1, &_renderFrameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _renderFrameBuffer);
    
    [self initCVOpenGLESTexture];
    
    // Create depth buffer
    glGenRenderbuffers(1, &depthBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, [self videoRect].size.width, [self videoRect].size.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthBuffer);
    
    // Test framebuffer for completenes
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER) ;
    
    if(status != GL_FRAMEBUFFER_COMPLETE) {
        
        NSLog(@"failed to make complete framebuffer object %x", status);
        return;
    }
    
    [self initVertexBuffers];
}

- (void)initCVOpenGLESTexture {
    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [EAGLContext currentContext], NULL, &videoTextureCache);
    
    if (err)
    {
        NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d", err);
    }
    
    glActiveTexture(GL_TEXTURE7);
    
    err = CVPixelBufferPoolCreatePixelBuffer (kCFAllocatorDefault, [[self assetWriterPixelBufferAdaptor] pixelBufferPool], &cvPixelBuffer);
    
    err = CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault,
                                                        videoTextureCache,
                                                        cvPixelBuffer,
                                                        NULL, //  texture attributes
                                                        GL_TEXTURE_2D,
                                                        GL_RGBA, //  opengl format
                                                        [self videoRect].size.width,
                                                        [self videoRect].size.height,
                                                        GL_BGRA, //  native iOS format
                                                        GL_UNSIGNED_BYTE,
                                                        0,
                                                        &renderTexture);    
    
    GLenum textureTarget = CVOpenGLESTextureGetTarget(renderTexture);
    GLuint textureName = CVOpenGLESTextureGetName(renderTexture);
    
    // Set renderTexture parameters
    glBindTexture(textureTarget, textureName);       
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    // Add renderTexture to FBO
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textureName, 0);
    
    // Restore active texture
    glActiveTexture(GL_TEXTURE0);
}

- (void)initVertexBuffers
{
    static const GLsizeiptr verticesSize = 4 * 2 * sizeof(GLfloat);
    static const GLfloat squareVertices[] = {
        -1.0f,    1.0f,
         1.0f,    1.0f,
        -1.0f,   -1.0f,
         1.0f,   -1.0f,
    };
    
    static const GLsizeiptr textureSize = 4 * 2 * sizeof(GLfloat);
    static const GLfloat squareTextureCoordinates[] = {
        0.0f,   1.0f,
        1.0f,   1.0f,
        0.0f,   0.0f,
        1.0f,   0.0f,
    };
    
    static const GLsizeiptr indexSize = 6 * sizeof(GLushort);
    static const GLushort indices[] = {
        0, 1, 2,
        2, 3, 1
    };
        
    glGenBuffers(1, &_indexVBO);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexVBO);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indexSize, indices, GL_STATIC_DRAW);
    
    glGenBuffers(1, &_positionVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _positionVBO);
    glBufferData(GL_ARRAY_BUFFER, verticesSize, squareVertices, GL_STATIC_DRAW);
    
    glEnableVertexAttribArray(POSITION_ATTRIBUTE);
    glVertexAttribPointer(POSITION_ATTRIBUTE, 2, GL_FLOAT, GL_FALSE, 2*sizeof(GLfloat), 0);
    
    glGenBuffers(1, &_texcoordVBO);
    glBindBuffer(GL_ARRAY_BUFFER, _texcoordVBO);
    glBufferData(GL_ARRAY_BUFFER, textureSize, squareTextureCoordinates, GL_DYNAMIC_DRAW);
    
    glEnableVertexAttribArray(TEXTURE_COORDINATE_ATTRIBUTE);
    glVertexAttribPointer(TEXTURE_COORDINATE_ATTRIBUTE, 2, GL_FLOAT, GL_FALSE, 2*sizeof(GLfloat), 0);
    
    // Reset buffers
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
}

- (void)showRenderTextureOnScreen {
    glBindFramebuffer(GL_FRAMEBUFFER, [self originalFrameBuffer]);
    glBindRenderbuffer(GL_RENDERBUFFER, [self originalRenderBuffer]);
    
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // Draw the texture to the original frame buffer with OpenGL ES 2.0
    [self renderTexture];
    
//    const GLenum discards[]  = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
//    glBindFramebuffer(GL_FRAMEBUFFER, _renderFrameBuffer);
//    glDiscardFramebufferEXT(GL_FRAMEBUFFER, 2, discards);
//    
//    glBindFramebuffer(GL_FRAMEBUFFER, [self originalFrameBuffer]);
//    glBindRenderbuffer(GL_RENDERBUFFER, [self originalRenderBuffer]);
    
    // Present render buffer on screen
    if(![[EAGLContext currentContext] presentRenderbuffer:GL_RENDERBUFFER])
        printf_console("failed to present renderbuffer (%s:%i)\n", __FILE__, __LINE__ );
}

- (void)renderTexture
{
    glUseProgram(passThroughProgram);
    
    int location = glGetUniformLocation(passThroughProgram, "videoframe");
    glActiveTexture(GL_TEXTURE0);
    glBindTexture( GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture) );
    glUniform1i(location, 0);
    
    glEnableVertexAttribArray(POSITION_ATTRIBUTE);
    glBindBuffer(GL_ARRAY_BUFFER, _positionVBO);
    glVertexAttribPointer(POSITION_ATTRIBUTE, 2, GL_FLOAT, 0, 0, 0);
    
    glEnableVertexAttribArray(TEXTURE_COORDINATE_ATTRIBUTE );
    glBindBuffer(GL_ARRAY_BUFFER, _texcoordVBO);
    glVertexAttribPointer(TEXTURE_COORDINATE_ATTRIBUTE, 2, GL_FLOAT, 0, 0, 0);
    
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexVBO);
    
    glDrawElements(GL_TRIANGLE_STRIP, 6, GL_UNSIGNED_SHORT, 0);
    
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
}

#pragma mark - Service functions

- (CGRect)videoRect {
    int width = [[UIScreen mainScreen] bounds].size.width;
    int height = [[UIScreen mainScreen] bounds].size.height;
    
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        width *= [[UIScreen mainScreen] scale];
        height *= [[UIScreen mainScreen] scale];
    }
    
    // Main screen bounds returns portrait orientation values
    if (UIInterfaceOrientationIsLandscape([[UIApplication sharedApplication] statusBarOrientation])) {
        return CGRectMake(0, 0, height, width);
    } else {
        return CGRectMake(0, 0, width, height);
    }
}

- (void)setupAssetWriter {
    
    // Create a shallow queue for buffers going to the display for preview.
    if (!previewBufferQueue) {
        CMBufferCallbacks *callbacks;
        callbacks = malloc(sizeof(CMBufferCallbacks));
        callbacks->version = 0;
        callbacks->getDuration = timeCallback;
        callbacks->refcon = NULL;
        callbacks->getDecodeTimeStamp = NULL;
        callbacks->getPresentationTimeStamp = NULL;
        callbacks->isDataReady = NULL;
        callbacks->compare = NULL;
        callbacks->dataBecameReadyNotification = NULL;
        
        CMBufferQueueCreate(kCFAllocatorDefault, 0, callbacks, &previewBufferQueue);
    }
    
    // Frame time calulates in milliseconds
    frameTime = CMTimeMake(1, 1000);
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[self outputVideoFileURL] path]]) {
        [[NSFileManager defaultManager] removeItemAtURL:[self outputVideoFileURL] error:nil];
    }
    
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[self outputVideoFileURL]
                                                      fileType:AVFileTypeAppleM4V
                                                         error:&error];
    NSParameterAssert(writer);
    
    CGRect videoRect = [self videoRect];
    
    NSNumber *videoWidth;
    NSNumber *videoHeight;
    
    if (UIInterfaceOrientationIsLandscape([[UIApplication sharedApplication] statusBarOrientation])) {
        videoWidth = [NSNumber numberWithInt:1024];
        videoHeight = [NSNumber numberWithInt:768];
    } else {
        videoWidth = [NSNumber numberWithInt:768];
        videoHeight = [NSNumber numberWithInt:1024];
    }
    
    NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   AVVideoCodecH264,    AVVideoCodecKey,
                                   videoWidth,          AVVideoWidthKey,
                                   videoHeight,         AVVideoHeightKey,
                                   nil];
    
    
    AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                         outputSettings:videoSettings];
    
    // Video caprtures upside down, so we need to flip it horizontal
    [writerInput setTransform:CGAffineTransformMake(1.0, 0.0, 0, -1.0, 0.0, [self videoRect].size.height)];
    
    // You need to use BGRA for the video in order to get realtime encoding.
    // I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                           [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                           [NSNumber numberWithInt:videoRect.size.width],      kCVPixelBufferWidthKey,
                                                           [NSNumber numberWithInt:videoRect.size.height],     kCVPixelBufferHeightKey,
                                                           [NSDictionary dictionary],                          kCVPixelBufferIOSurfacePropertiesKey,
                                                           nil];
    
    AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferAdaptor =
    [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                                     sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    NSParameterAssert(writerInput);
    NSParameterAssert([writer canAddInput:writerInput]);
    
    [writer addInput:writerInput];
    
    [self setWriter:writer];
    [self setWriterInput:writerInput];
    [self setAssetWriterPixelBufferAdaptor:assetWriterPixelBufferAdaptor];
    
    [writer release];
    
    _audioWriter = [[CRAudioWriter alloc] init];
    [[self audioWriter] setOutputAudioFile:[self outputAudioFileURL]];
}

CMTime timeCallback(CMBufferRef buf, void *refcon){
    return CMTimeMake(1, 1000);
}

- (void)mergeVideo:(NSURL *)videoUrl withAudio:(NSURL *)audioUrl {
    AVMutableComposition *composition = [AVMutableComposition composition];
    
    // Create video track for composition
    AVURLAsset *videoAsset = [[AVURLAsset alloc] initWithURL:[self outputVideoFileURL] options:nil];
    AVAssetTrack *sourceVideoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    
    AVMutableCompositionTrack *compositionVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                                preferredTrackID:kCMPersistentTrackID_Invalid];
    
    [compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration)
                                   ofTrack:sourceVideoTrack
                                    atTime:kCMTimeZero error:nil];
    
    // This property sets exported video orientation
    [compositionVideoTrack setPreferredTransform:sourceVideoTrack.preferredTransform];
    
    // Create audio track for composition
    AVURLAsset* audioAsset = [[AVURLAsset alloc]initWithURL:[self outputAudioFileURL] options:nil];
    AVAssetTrack *sourceAudioTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];
    
    AVMutableCompositionTrack *compositionAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                                preferredTrackID:kCMPersistentTrackID_Invalid];
    
    [compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioAsset.duration)
                                   ofTrack:sourceAudioTrack
                                    atTime:kCMTimeZero error:nil];
       
    // Export merged video to the Photo Library
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[self exportedVideoURL] path]])
    {
        [[NSFileManager defaultManager] removeItemAtPath:[[self exportedVideoURL] path] error:nil];
    }
    
    AVAssetExportSession* _assetExport = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                          presetName:AVAssetExportPresetPassthrough];
    
    _assetExport.outputFileType = @"com.apple.quicktime-movie";
    _assetExport.outputURL = [self exportedVideoURL];
    _assetExport.shouldOptimizeForNetworkUse = YES;
    
    
    [_assetExport exportAsynchronouslyWithCompletionHandler:^{
        
         switch (_assetExport.status)
         {
             case AVAssetExportSessionStatusCompleted: {
                 ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                 if ([library videoAtPathIsCompatibleWithSavedPhotosAlbum:[self exportedVideoURL]])
                 {
                     [library writeVideoAtPathToSavedPhotosAlbum:[self exportedVideoURL]
                                                 completionBlock:^(NSURL *assetURL, NSError *error) {
                                                     [self removeTemporaryFiles];
                                                     NSLog(@"Export Complete");
                                                 }];
                 }
                 [library release];
                 break;
             }
             case AVAssetExportSessionStatusFailed:
                 NSLog(@"Export Failed");
                 NSLog(@"ExportSessionError: %@", [_assetExport.error localizedDescription]);
                 break;
             case AVAssetExportSessionStatusCancelled:
                 NSLog(@"Export Cancelled");
                 NSLog(@"ExportSessionError: %@", [_assetExport.error localizedDescription]);
                 break;
         }
     }];
}

- (void)removeTemporaryFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *temporaryFiles = @ [
                                [[self exportedVideoURL] path],
                                [[self outputAudioFileURL] path],
                                [[self outputVideoFileURL] path]
                                ];
    for (NSString *path in temporaryFiles) {
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
        }
    }
}


- (const GLchar *)readFile:(NSString *)name {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType: nil];
    const GLchar *source = (GLchar *)[[NSString stringWithContentsOfFile:path
                                                                encoding:NSUTF8StringEncoding error:nil] UTF8String];
    return source;
}

- (void)compileShadersForTextureDrawing {
    // Load vertex and fragment shaders
    const GLchar *vertSrc = [self readFile:@"passThrough.vsh"];
    const GLchar *fragSrc = [self readFile:@"passThrough.fsh"];
    
    // Set shader attributes
    GLint attribLocation[NUM_ATTRIBUTES] = {
        POSITION_ATTRIBUTE, TEXTURE_COORDINATE_ATTRIBUTE,
    };
    GLchar *attribName[NUM_ATTRIBUTES] = {
        "position", "textureCoordinate",
    };
    
    glueCreateProgram(vertSrc, fragSrc,
                      NUM_ATTRIBUTES, (const GLchar **)&attribName[0], attribLocation,
                      0, 0, 0, //  we don't need to get uniform locations
                      &passThroughProgram);
    
    //uniforms[UNIFORM_TEXTURE] = glGetUniformLocation(passThroughProgram, "videoframe");
}

- (CGRect)textureSamplingRectForCroppingTextureWithAspectRatio:(CGSize)textureAspectRatio toAspectRatio:(CGSize)croppingAspectRatio {
	CGRect normalizedSamplingRect = CGRectZero;
	CGSize cropScaleAmount = CGSizeMake(croppingAspectRatio.width / textureAspectRatio.width, croppingAspectRatio.height / textureAspectRatio.height);
	CGFloat maxScale = fmax(cropScaleAmount.width, cropScaleAmount.height);
	CGSize scaledTextureSize = CGSizeMake(textureAspectRatio.width * maxScale, textureAspectRatio.height * maxScale);
	
	if ( cropScaleAmount.height > cropScaleAmount.width ) {
		normalizedSamplingRect.size.width = croppingAspectRatio.width / scaledTextureSize.width;
		normalizedSamplingRect.size.height = 1.0;
	}
	else {
		normalizedSamplingRect.size.height = croppingAspectRatio.height / scaledTextureSize.height;
		normalizedSamplingRect.size.width = 1.0;
	}
	// Center crop
	normalizedSamplingRect.origin.x = (1.0 - normalizedSamplingRect.size.width)/2.0;
	normalizedSamplingRect.origin.y = (1.0 - normalizedSamplingRect.size.height)/2.0;
	
	return normalizedSamplingRect;
}

@end
