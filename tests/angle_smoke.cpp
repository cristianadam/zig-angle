// angle_smoke - exercises a zig-angle build the way a real consumer would.
//
// It includes only the installed public headers and links only libEGL and
// libGLESv2, so it doubles as a check that the installed include/ tree and the
// exported symbol set are actually usable from outside the build.
//
// The context it asks for is the one a WebGL implementation asks ANGLE for:
// EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE plus
// EGL_ROBUST_RESOURCE_INITIALIZATION_ANGLE. Both come from
// EGL/eglext_angle.h. Beyond tightening validation to WebGL's rules, robust
// resource initialization is what guarantees that freshly allocated storage
// reads back as zeros instead of whatever was in GPU memory - checked below.
//
//   angle_smoke [backend]
//
// where backend is default (the ANGLE default for the platform), d3d11, gl,
// gles, metal, vulkan or null. Exits 0 if every check passed.

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr EGLint kWidth  = 64;
constexpr EGLint kHeight = 64;

// CTest's SKIP_RETURN_CODE. Returned when EGL cannot be brought up at all,
// which on a headless or driverless box says nothing about the build.
constexpr int kSkip = 77;

int g_failures = 0;

void pass(const char *what)
{
    std::printf("  [ ok ] %s\n", what);
}

void fail(const char *what, const std::string &detail)
{
    std::printf("  [FAIL] %s: %s\n", what, detail.c_str());
    ++g_failures;
}

void check(bool ok, const char *what, const std::string &detail = {})
{
    if (ok)
        pass(what);
    else
        fail(what, detail.empty() ? "condition not met" : detail);
}

std::string eglErrorString()
{
    char buf[64];
    std::snprintf(buf, sizeof(buf), "eglGetError() = 0x%04X", eglGetError());
    return buf;
}

bool hasExtension(const char *extensions, const char *name)
{
    if (!extensions)
        return false;
    const size_t len = std::strlen(name);
    for (const char *p = extensions; (p = std::strstr(p, name)) != nullptr; p += len)
    {
        const bool leftOk  = (p == extensions) || p[-1] == ' ';
        const bool rightOk = p[len] == ' ' || p[len] == '\0';
        if (leftOk && rightOk)
            return true;
    }
    return false;
}

EGLint backendFromName(const char *name)
{
    if (!name || !std::strcmp(name, "default"))
        return EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE;
    if (!std::strcmp(name, "d3d11"))
        return EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE;
    if (!std::strcmp(name, "null"))
        return EGL_PLATFORM_ANGLE_TYPE_NULL_ANGLE;
    if (!std::strcmp(name, "gl"))
        return EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE;
    if (!std::strcmp(name, "gles"))
        return EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE;
    if (!std::strcmp(name, "metal"))
        return EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE;
    if (!std::strcmp(name, "vulkan"))
        return EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE;
    std::printf("unknown backend '%s', using the platform default\n", name);
    return EGL_PLATFORM_ANGLE_TYPE_DEFAULT_ANGLE;
}

GLuint compile(GLenum stage, const char *source)
{
    GLuint shader = glCreateShader(stage);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok)
    {
        GLint len = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &len);
        std::vector<char> log(len > 1 ? len : 1);
        glGetShaderInfoLog(shader, static_cast<GLsizei>(log.size()), nullptr, log.data());
        fail("shader compiles", log.data());
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

// Draws a triangle covering the whole viewport in a known colour and reads the
// centre pixel back. This is the path that actually runs ANGLE's shader
// translator, so it catches far more than a bare glClear would.
void testDraw()
{
    static const char kVertex[] =
        "attribute vec2 aPos;\n"
        "void main() { gl_Position = vec4(aPos, 0.0, 1.0); }\n";
    static const char kFragment[] =
        "precision mediump float;\n"
        "uniform vec4 uColor;\n"
        "void main() { gl_FragColor = uColor; }\n";

    GLuint vs = compile(GL_VERTEX_SHADER, kVertex);
    GLuint fs = compile(GL_FRAGMENT_SHADER, kFragment);
    if (!vs || !fs)
        return;
    pass("shader compiles");

    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "aPos");
    glLinkProgram(program);

    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked)
    {
        GLint len = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &len);
        std::vector<char> log(len > 1 ? len : 1);
        glGetProgramInfoLog(program, static_cast<GLsizei>(log.size()), nullptr, log.data());
        fail("program links", log.data());
        return;
    }
    pass("program links");

    glUseProgram(program);
    glUniform4f(glGetUniformLocation(program, "uColor"), 0.0f, 1.0f, 0.0f, 1.0f);

    // One oversized triangle is enough to cover the viewport.
    static const GLfloat kVerts[] = {-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};
    GLuint buffer = 0;
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kVerts), kVerts, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);

    glViewport(0, 0, kWidth, kHeight);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    GLubyte px[4] = {0, 0, 0, 0};
    glReadPixels(kWidth / 2, kHeight / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);

    const GLenum err = glGetError();
    check(err == GL_NO_ERROR, "draw raises no GL error",
          "glGetError() = 0x" + std::to_string(err));

    char detail[80];
    std::snprintf(detail, sizeof(detail), "read back RGBA(%u, %u, %u, %u)", px[0], px[1], px[2],
                  px[3]);
    check(px[0] < 16 && px[1] > 239 && px[2] < 16 && px[3] > 239, "triangle renders green", detail);
    std::printf("         %s\n", detail);

    glDeleteBuffers(1, &buffer);
    glDeleteProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
}

// With EGL_ROBUST_RESOURCE_INITIALIZATION_ANGLE - which is not optional for a
// WebGL implementation - a renderbuffer that has never been written must read
// back as zeros rather than leaking whatever the driver had in that memory.
void testRobustResourceInit()
{
    GLuint rb = 0;
    glGenRenderbuffers(1, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA4, kWidth, kHeight);

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
    {
        fail("uninitialized renderbuffer reads as zeros", "framebuffer incomplete");
    }
    else
    {
        std::vector<GLubyte> px(static_cast<size_t>(kWidth) * kHeight * 4, 0xAB);
        glReadPixels(0, 0, kWidth, kHeight, GL_RGBA, GL_UNSIGNED_BYTE, px.data());

        size_t nonZero = 0;
        for (GLubyte v : px)
        {
            if (v != 0)
                ++nonZero;
        }
        check(nonZero == 0, "uninitialized renderbuffer reads as zeros",
              std::to_string(nonZero) + " of " + std::to_string(px.size()) +
                  " bytes were not zero");
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);
    glDeleteRenderbuffers(1, &rb);
}

const char *glString(GLenum name)
{
    const GLubyte *s = glGetString(name);
    return s ? reinterpret_cast<const char *>(s) : "(null)";
}

}  // namespace

int main(int argc, char **argv)
{
    // Unbuffered, so that if a driver takes the process down mid-test the
    // output still shows how far it got.
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    const EGLint backend = backendFromName(argc > 1 ? argv[1] : nullptr);

    const char *clientExtensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);

    EGLDisplay display = EGL_NO_DISPLAY;
    if (hasExtension(clientExtensions, "EGL_ANGLE_platform_angle"))
    {
        auto getPlatformDisplayEXT = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
            eglGetProcAddress("eglGetPlatformDisplayEXT"));
        if (getPlatformDisplayEXT)
        {
            std::vector<EGLint> displayAttribs = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, backend};
#if defined(__linux__)
            // On Linux this build has neither X11, Wayland nor GBM compiled in
            // (they would all need headers zig does not ship), so ANGLE's
            // CreateDisplayFromAttribs has exactly two ways to hand back a
            // DisplayEGL: an explicit EGL device type, or the surfaceless Mesa
            // platform. Ask for the first - it is the same thing WebKit's
            // GTK/WPE ports request, and without it eglGetDisplay just returns
            // EGL_NO_DISPLAY with EGL_SUCCESS.
            displayAttribs.insert(displayAttribs.end(),
                                  {EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
                                   EGL_PLATFORM_ANGLE_DEVICE_TYPE_EGL_ANGLE});
#endif
            displayAttribs.push_back(EGL_NONE);

            // The EXT entry point takes void *, not EGLNativeDisplayType, and
            // EGL_DEFAULT_DISPLAY is ((EGLNativeDisplayType)0) - which on Apple
            // is an int and will not convert. nullptr is the same "no native
            // display" request and is portable.
            display =
                getPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttribs.data());
        }
    }
    if (display == EGL_NO_DISPLAY)
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);

    if (display == EGL_NO_DISPLAY)
    {
        std::printf("  [skip] no EGLDisplay: %s\n", eglErrorString().c_str());
        return kSkip;
    }

    // Worth announcing: a backend with no usable driver underneath can take the
    // process down inside eglInitialize rather than returning EGL_FALSE, and
    // then this is the last line you see.
    std::printf("display obtained, initializing...\n");

    EGLint major = 0, minor = 0;
    if (!eglInitialize(display, &major, &minor))
    {
        std::printf("  [skip] eglInitialize: %s\n", eglErrorString().c_str());
        return kSkip;
    }
    std::printf("EGL %d.%d  vendor: %s\n", major, minor, eglQueryString(display, EGL_VENDOR));
    std::printf("EGL version string: %s\n", eglQueryString(display, EGL_VERSION));

    const char *displayExtensions = eglQueryString(display, EGL_EXTENSIONS);
    const bool webglCompat =
        hasExtension(displayExtensions, "EGL_ANGLE_create_context_webgl_compatibility");
    const bool robustInit =
        hasExtension(displayExtensions, "EGL_ANGLE_robust_resource_initialization");
    std::printf("WebGL compatibility contexts: %s\n", webglCompat ? "yes" : "no");
    std::printf("Robust resource initialization: %s\n", robustInit ? "yes" : "no");

    const EGLint configAttribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                    EGL_RED_SIZE, 8,
                                    EGL_GREEN_SIZE, 8,
                                    EGL_BLUE_SIZE, 8,
                                    EGL_ALPHA_SIZE, 8,
                                    EGL_NONE};
    EGLConfig config = nullptr;
    EGLint configCount = 0;
    if (!eglChooseConfig(display, configAttribs, &config, 1, &configCount) || configCount == 0)
    {
        std::printf("  [skip] eglChooseConfig: %s\n", eglErrorString().c_str());
        return kSkip;
    }
    pass("eglChooseConfig found a pbuffer config");

    const EGLint surfaceAttribs[] = {EGL_WIDTH, kWidth, EGL_HEIGHT, kHeight, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, surfaceAttribs);
    if (surface == EGL_NO_SURFACE)
    {
        std::printf("  [skip] eglCreatePbufferSurface: %s\n", eglErrorString().c_str());
        return kSkip;
    }
    pass("pbuffer surface created");

    std::vector<EGLint> contextAttribs = {EGL_CONTEXT_CLIENT_VERSION, 2};
    if (webglCompat)
        contextAttribs.insert(contextAttribs.end(),
                              {EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE, EGL_TRUE});
    if (robustInit)
        contextAttribs.insert(contextAttribs.end(),
                              {EGL_ROBUST_RESOURCE_INITIALIZATION_ANGLE, EGL_TRUE});
    contextAttribs.push_back(EGL_NONE);

    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs.data());
    if (context == EGL_NO_CONTEXT)
    {
        std::printf("  [skip] eglCreateContext: %s\n", eglErrorString().c_str());
        return kSkip;
    }
    check(true, webglCompat ? "WebGL-compatibility ES2 context created"
                            : "ES2 context created (no WebGL compatibility extension)");

    if (!eglMakeCurrent(display, surface, surface, context))
    {
        std::printf("  [skip] eglMakeCurrent: %s\n", eglErrorString().c_str());
        return kSkip;
    }
    pass("context made current");

    std::printf("GL_VENDOR:   %s\n", glString(GL_VENDOR));
    std::printf("GL_RENDERER: %s\n", glString(GL_RENDERER));
    std::printf("GL_VERSION:  %s\n", glString(GL_VERSION));
    std::printf("GLSL:        %s\n", glString(GL_SHADING_LANGUAGE_VERSION));

    testDraw();
    if (robustInit)
        testRobustResourceInit();
    else
        std::printf("  [skip] uninitialized renderbuffer reads as zeros (extension absent)\n");

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);

    std::printf("\n%s\n", g_failures == 0 ? "angle_smoke: PASS" : "angle_smoke: FAIL");
    return g_failures == 0 ? 0 : 1;
}
