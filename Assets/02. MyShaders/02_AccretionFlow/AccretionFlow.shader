// =====================================================================
//  02 AccretionFlow — 강착원반 소용돌이 (바탕: 갤러리 '플로 맵 액체')
//  플로 맵에 "회전(접선) + 중심으로 빨려드는 방향"을 구워 두고,
//  무늬를 그 흐름대로 두 위상으로 흘려 끊김 없는 소용돌이 가스를 만든다.
//  색은 원본처럼 무늬 밝기로 어두운 색 ↔ 밝은 색을 섞고 밝은 부분을 발광시킨다.
//  바꾼 점:
//    · 구에 맞춘 소용돌이 UV + 중심의 검은 핵
//    · 크기·속도가 다른 두 흐름 층을 곱해 가는 필라멘트 무늬를 만든다
//    · 중심에 가까울수록 뜨거운 색(온도), 회전해 다가오는 쪽이 더 밝다(도플러)
//  그리기 모드(프로퍼티 하나):
//    · Opaque   : 볼 2 처럼 표면 자체가 가스
//    · Additive : 01 렌즈 머티리얼 위에 두 번째 머티리얼로 겹쳐(큐 3001) 휜 장면 위에 가스만 더한다
// =====================================================================
Shader "MyShaders/AccretionFlow"
{
    Properties
    {
        [Header(Flow)]
        [NoScaleOffset] _FlowMap    ("Flow Map (RG = direction, B = phase noise, sRGB off)", 2D) = "linearGrey" {}
        [NoScaleOffset] _PatternTex ("Gas Pattern", 2D) = "gray" {}
        _VortexRadius ("Vortex Radius (world)", Float) = 0.55
        _FlowStrength ("Flow Strength", Range(0, 1)) = 0.35
        _FlowSpeed    ("Flow Speed", Range(0, 2)) = 0.35
        _NoiseScale   ("Pattern Scale", Range(0.5, 8)) = 2.5
        _PhaseNoise   ("Phase Noise", Range(0, 1)) = 0.6
        _DetailScale  ("Detail Layer Scale (x Pattern)", Range(1, 5)) = 2.3

        [Header(Gas Color)]
        _DeepColor   ("Deep Color", Color) = (0.17, 0.04, 0.02, 1)
        _BrightColor ("Bright Color", Color) = (1, 0.42, 0.08, 1)
        [HDR] _HotColor ("Hot Color (inner)", Color) = (1.15, 0.78, 0.42, 1)
        _HeatPower   ("Heat Falloff", Range(0.5, 6)) = 3
        _Glow        ("Bright Glow", Range(0, 4)) = 0.8
        _Doppler     ("Doppler Brightness", Range(0, 1)) = 0.45

        [Header(Core)]
        _CoreRadius   ("Core Radius (0-1)", Range(0, 1)) = 0.18
        _CoreSoftness ("Core Softness", Range(0.001, 0.3)) = 0.06

        [Header(Draw Mode)]
        [Enum(Opaque, 0, Additive, 1)] _DstBlend ("Mode (Additive = overlay on lens, queue 3001)", Float) = 0
    }

    SubShader
    {
        // Opaque 큐: Opaque Texture 에 찍혀야 01 렌즈가 이 가스를 휘게 할 수 있다
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" "RenderPipeline" = "UniversalPipeline" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "../Shared/BlackHoleCommon.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float  _VortexRadius;
            float  _FlowStrength;
            float  _FlowSpeed;
            float  _NoiseScale;
            float  _PhaseNoise;
            float  _DetailScale;
            float4 _DeepColor;
            float4 _BrightColor;
            float4 _HotColor;
            float  _HeatPower;
            float  _Glow;
            float  _Doppler;
            float  _CoreRadius;
            float  _CoreSoftness;
            float  _DstBlend;
        CBUFFER_END

        TEXTURE2D(_FlowMap);  SAMPLER(sampler_FlowMap);
        TEXTURE2D(_PatternTex); SAMPLER(sampler_PatternTex);
        ENDHLSL

        Pass
        {
            Name "ForwardUnlit"
            Tags { "LightMode" = "UniversalForward" }
            // Opaque: One Zero(덮어쓰기) / Additive: One One(더하기). BlendMode 값 0 = Zero, 1 = One
            Blend One [_DstBlend]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionWS = TransformObjectToWorld(v.positionOS.xyz);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                return o;
            }

            float4 frag(Varyings i) : SV_Target
            {
                float3 centerWS = BH_CenterWS();

                // 1) 표면 → 소용돌이 UV (관찰자를 향한 원판 좌표). 플로 맵과 무늬를 모두 이 UV 로 읽는다
                float2 uv = BH_VortexUV(i.positionWS, centerWS, _VortexRadius);
                float2 d  = uv * 2.0 - 1.0;
                float  r  = length(d);

                // 2) 플로 맵 + 두 위상 섞기 (갤러리 원본과 같은 방식)를 두 층으로
                //    큰 층: 기본 소용돌이 / 작은 층: 더 잘고 빠르게 흐르는 무늬
                //    두 층을 곱하면 둘 다 밝은 곳만 남아 가는 가스 줄기(필라멘트)가 된다
                float big = BH_FlowNoise(TEXTURE2D_ARGS(_FlowMap, sampler_FlowMap), TEXTURE2D_ARGS(_PatternTex, sampler_PatternTex),
                                         uv, _FlowStrength, _FlowSpeed, _NoiseScale, _PhaseNoise, _Time.y);
                float small = BH_FlowNoise(TEXTURE2D_ARGS(_FlowMap, sampler_FlowMap), TEXTURE2D_ARGS(_PatternTex, sampler_PatternTex),
                                           uv, _FlowStrength * 1.5, _FlowSpeed * 1.6, _NoiseScale * _DetailScale, _PhaseNoise, _Time.y + 7.3);
                float pat = saturate(big * small * 2.2);

                // 3) 온도: 중심(핵 가장자리)에 가까울수록 1 → 밝은 색을 뜨거운 색으로 바꾼다
                float heat = pow(saturate(1.0 - (r - _CoreRadius) / max(1.0 - _CoreRadius, 1e-3)), _HeatPower);
                float3 tint = lerp(_BrightColor.rgb, _HotColor.rgb, heat);

                // 4) 색: 원본과 같은 식(어두운 색 ↔ 밝은 색 + 발광), 밝은 색 자리에 온도 색을 쓴다
                float3 col = lerp(_DeepColor.rgb, tint, pat) + tint * (pat * pat) * _Glow;

                // 5) 도플러: 회전하며 관찰자 쪽으로 다가오는 한쪽(화면 왼쪽)이 더 밝다
                col *= 1.0 + _Doppler * (-d.x / max(r, 1e-3)) * saturate(r * 4.0);

                // 6) 중심의 검은 핵 — 가스가 빨려 들어가 사라지는 곳
                col *= smoothstep(_CoreRadius - _CoreSoftness, _CoreRadius + _CoreSoftness, r);

                return float4(col, 1.0);
            }
            ENDHLSL
        }

        // ---- 그림자 / 깊이 / 깊이+법선 (SSAO, Depth Texture 용) ----
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            ZWrite On ZTest LEqual ColorMask 0

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            float3 _LightDirection;
            float3 _LightPosition;

            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; };
            struct Varyings   { float4 positionCS : SV_POSITION; };

            Varyings vert(Attributes v)
            {
                Varyings o;
                float3 posWS = TransformObjectToWorld(v.positionOS.xyz);
                float3 nWS   = TransformObjectToWorldNormal(v.normalOS);
            #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                float3 lightDir = normalize(_LightPosition - posWS);
            #else
                float3 lightDir = _LightDirection;
            #endif
                o.positionCS = TransformWorldToHClip(ApplyShadowBias(posWS, nWS, lightDir));
            #if UNITY_REVERSED_Z
                o.positionCS.z = min(o.positionCS.z, UNITY_NEAR_CLIP_VALUE);
            #else
                o.positionCS.z = max(o.positionCS.z, UNITY_NEAR_CLIP_VALUE);
            #endif
                return o;
            }
            half4 frag(Varyings i) : SV_Target { return 0; }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On ColorMask R

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings   { float4 positionCS : SV_POSITION; };
            Varyings vert(Attributes v) { Varyings o; o.positionCS = TransformObjectToHClip(v.positionOS.xyz); return o; }
            half frag(Varyings i) : SV_Target { return i.positionCS.z; }
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }
            ZWrite On

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; };
            struct Varyings   { float4 positionCS : SV_POSITION; float3 normalWS : TEXCOORD0; };
            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                o.normalWS   = TransformObjectToWorldNormal(v.normalOS);
                return o;
            }
            half4 frag(Varyings i) : SV_Target { return half4(NormalizeNormalPerPixel(i.normalWS), 0.0); }
            ENDHLSL
        }
    }
    FallBack Off
}
