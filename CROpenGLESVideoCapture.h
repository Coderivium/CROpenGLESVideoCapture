//
//  CROpenGLESVideoCapture.h
//  Unity-iPhone
//
//  Created by Dmitry Utenkov on 19.02.13.
//
//

#import <Foundation/Foundation.h>

@interface CROpenGLESVideoCapture : NSObject 

+ (CROpenGLESVideoCapture *)sharedInstance;

@property (nonatomic, readonly, assign) BOOL isCapturing;

//Original OpenGL buffers
@property (nonatomic, assign) GLuint originalFrameBuffer;
@property (nonatomic, assign) GLuint originalRenderBuffer;
@property (nonatomic, assign) GLuint originalDepthBuffer;

//Frame buffer for rendering to texture
//Should be bound as GL_FRAMEBUFFER before rendering
@property (nonatomic, readonly, assign) GLuint renderFrameBuffer;

//This method should be called after frame rendering
- (void)newFrameReady;

- (void)startCapturing;
- (void)endCapturing;

@end
