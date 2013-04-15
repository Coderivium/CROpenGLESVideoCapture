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
#import "AudioWriter.h"

enum {
    ATTRIB_VERTEX,
    ATTRIB_TEXTUREPOSITION,
    NUM_ATTRIBUTES
};

// Uniform index.
enum {
    UNIFORM_TEXTURE,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

@interface CROpenGLESVideoCapture () {
    CVOpenGLESTextureRef    renderTexture;
    CVPixelBufferRef        cvPixelBuffer;
    CMTime                  frameTime;
    GLuint                  passThroughProgram;
}

@property (nonatomic, assign)   BOOL                                    isCapturing;
@property (nonatomic, retain)   NSURL                                   *outputVideoFileURL;
@property (nonatomic, retain)   NSURL                                   *outputAudioFileURL;
@property (nonatomic, retain)   NSURL                                   *exportedVideoURL;
@property (nonatomic, retain)   AVAssetWriter                           *writer;
@property (nonatomic, retain)   AVAssetWriterInput                      *writerInput;
@property (nonatomic, retain)   AVAssetWriterInputPixelBufferAdaptor    *assetWriterPixelBufferAdaptor;
@property (nonatomic, retain)   AudioWriter                             *audioWriter;

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
    [[self writer] startSessionAtSourceTime:kCMTimeZero];
    
    // Setting up buffer for rendering to texture should be done after starting session
    // because pixelBufferPool returns nil before it
    [self initRenderBuffer];
    
    [[self audioWriter] startRecording];
    [self setIsCapturing:YES];
}

- (void)endCapturing {
    [self setIsCapturing:NO];
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
    glFinish();
    
    // Appending rendered frame to output video file
    CVPixelBufferLockBaseAddress(cvPixelBuffer, 0);
    if([[self assetWriterPixelBufferAdaptor] appendPixelBuffer:cvPixelBuffer
                                          withPresentationTime:frameTime] == NO)
    {
        NSLog(@"Problem appending pixel buffer at time: %lld", frameTime.value);
    }
    else
    {
        frameTime.value++;
    }
    CVPixelBufferUnlockBaseAddress(cvPixelBuffer, 0);
    
    [self showRenderTextureOnScreen];
}

#pragma mark - Frame rendering

- (void)initRenderBuffer {
    // Create framebuffer
    glGenFramebuffers(1, &_renderFrameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _renderFrameBuffer);
    
    [self initCVOpenGLESTexture];
    
    // Create depth buffer
    GLuint depthBuffer = 0;
    glGenRenderbuffers(1, &depthBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, [self videoRect].size.width, [self videoRect].size.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthBuffer);
    
    
    //glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, [self originalDepthBuffer]);
    
    // Test framebuffer for completenes
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER) ;
    
    if(status != GL_FRAMEBUFFER_COMPLETE) {
        
        NSLog(@"failed to make complete framebuffer object %x", status);
        return;
    }
}

- (void)initCVOpenGLESTexture {
    CVOpenGLESTextureCacheRef videoTextureCache;
    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [EAGLContext currentContext], NULL, &videoTextureCache);
    
    if (err)
    {
        NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d", err);
    }
    
    glActiveTexture(GL_TEXTURE0 + GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS - 1);
    
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

- (void)showRenderTextureOnScreen {
    glBindFramebuffer(GL_FRAMEBUFFER, [self originalFrameBuffer]);
    glBindRenderbuffer(GL_RENDERBUFFER, [self originalRenderBuffer]);
    
    glClearColor(1.0, 1.0, 1.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // Set texture polygons drawing order
    // -1, -1 - lower left corner
    //  1,  1 - upper right corner
    static const GLfloat squareVertices[] = {
        -1.0f,    1.0f,
         1.0f,    1.0f,
        -1.0f,   -1.0f,
         1.0f,   -1.0f,
    };
    
    int renderBufferWidth = 0;
    int renderBufferHeight = 0;
    
    // Get renderbuffer dimensions
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &renderBufferWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &renderBufferHeight);
    
    // The texture vertices are set up such that we flip the texture vertically.
    // This is so that our top left origin buffers match OpenGL's bottom left texture coordinate system.
    CGRect textureSamplingRect = [self textureSamplingRectForCroppingTextureWithAspectRatio:CGSizeMake(renderBufferWidth, renderBufferHeight)
                                                                              toAspectRatio:CGSizeMake(renderBufferWidth, renderBufferHeight)];
    GLfloat textureVertices[] = {
        CGRectGetMinX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
        CGRectGetMaxX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
        CGRectGetMinX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
        CGRectGetMaxX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
    };
    
    // Draw the texture to the original frame buffer with OpenGL ES 2.0
    [self renderWithSquareVertices:squareVertices textureVertices:textureVertices];
    
    // Present render buffer on screen
    if(![[EAGLContext currentContext] presentRenderbuffer:GL_RENDERBUFFER])
        printf_console("failed to present renderbuffer (%s:%i)\n", __FILE__, __LINE__ );
}

- (void)renderWithSquareVertices:(const GLfloat*)squareVertices textureVertices:(const GLfloat*)textureVertices {   
    // Erase buffers for drawing
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);

    // Use shader program
    glUseProgram(passThroughProgram);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture( GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture) );
    glUniform1i(uniforms[UNIFORM_TEXTURE], 0);
    
    // Update attribute values.
    glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, 0, 0, squareVertices);
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    glVertexAttribPointer(ATTRIB_TEXTUREPOSITION, 2, GL_FLOAT, 0, 0, textureVertices);
	glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITION);
    
    // Draw render texture on screen
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

#pragma mark - Service functions

- (CGRect)videoRect {
    int width = [[UIScreen mainScreen] bounds].size.width;
    int height = [[UIScreen mainScreen] bounds].size.height;
    
    if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)]) {
        width *= [[UIScreen mainScreen] scale];
        height *= [[UIScreen mainScreen] scale];
    }
    return CGRectMake(0, 0, width, height);
}

- (void)setupAssetWriter {
    frameTime = CMTimeMake(0, 30);
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[self outputVideoFileURL] path]]) {
        [[NSFileManager defaultManager] removeItemAtURL:[self outputVideoFileURL] error:nil];
    }
    
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[self outputVideoFileURL]
                                                      fileType:AVFileTypeAppleM4V
                                                         error:&error];
    NSParameterAssert(writer);
    
    CGRect videoRect = [self videoRect];
    
    NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   AVVideoCodecH264,                               AVVideoCodecKey,
                                   [NSNumber numberWithInt:[[UIScreen mainScreen] bounds].size.width],  AVVideoWidthKey,
                                   [NSNumber numberWithInt:[[UIScreen mainScreen] bounds].size.height], AVVideoHeightKey,
                                   nil];
    
    
    AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                         outputSettings:videoSettings];
    
    // Video caprtures upside down, so we need to flip it horizontal
    // This attribute will handle landscape orientation
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
    
    _audioWriter = [[AudioWriter alloc] init];
    [[self audioWriter] setOutputAudioFile:[self outputAudioFileURL]];
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
        ATTRIB_VERTEX, ATTRIB_TEXTUREPOSITION,
    };
    GLchar *attribName[NUM_ATTRIBUTES] = {
        "position", "textureCoordinate",
    };
    
    glueCreateProgram(vertSrc, fragSrc,
                      NUM_ATTRIBUTES, (const GLchar **)&attribName[0], attribLocation,
                      0, 0, 0, //  we don't need to get uniform locations
                      &passThroughProgram);
    
    uniforms[UNIFORM_TEXTURE] = glGetUniformLocation(passThroughProgram, "videoframe");
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
