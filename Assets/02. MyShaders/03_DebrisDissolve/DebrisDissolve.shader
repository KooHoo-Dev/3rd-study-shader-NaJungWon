// =====================================================================
//  03 DebrisDissolve — 생성되고 중심으로 빨려 드는 잔해 (바탕: 갤러리 '디졸브')
//  원본: 노이즈 < 임계값 이면 잘라 내고, 임계값 바로 위 띠를 발광시킨다.
//  바꾼 점:
//    · 임계값(_Threshold)을 한 바퀴의 진행 시간으로 쓰고, _AutoPlay 로 셰이더 안에서 반복한다
//    · 생성 구간: 디졸브를 거꾸로(잘라 내는 기준 1 → 0) 돌려 타오르며 나타난다
//    · 흡입 구간: 덩어리마다 시차를 두고 중심(구의 중심)으로 나선을 그리며 가속해 빨려 들고,
//                 그 진행도가 곧 잘라 내는 기준이 되어 빨려 들면서 타 사라진다 (정점 변형)
// =====================================================================
Shader "MyShaders/DebrisDissolve"
{
    Properties
    {
        _BaseColor ("Base Color", Color) = (0.42, 0.38, 0.35, 1)

        [Header(Threshold)]
        _Threshold ("Threshold (one cycle 0-1)", Range(0, 1)) = 0.5
        [ToggleUI] _AutoPlay ("Auto Play (loop threshold)", Float) = 1
        _CycleSpeed ("Cycle Speed", Range(0, 1)) = 0.12

        [Header(Dissolve Edge)]
        _NoiseScale ("Noise Scale", Range(1, 30)) = 9
        _EdgeWidth  ("Edge Width", Range(0.005, 0.25)) = 0.07
        [HDR] _EdgeColor ("Edge Color", Color) = (1.5, 0.55, 0.15, 1)

        [Header(Form and Pull)]
        _FormDuration ("Form Duration (0-1)", Range(0.01, 0.5)) = 0.15
        _PullStart    ("Pull Start (0-1)", Range(0, 0.95)) = 0.3
        _PullDuration ("Pull Duration per Chunk (0-1)", Range(0.05, 0.7)) = 0.3
        _ChunkScale   ("Chunk Size (delay noise scale)", Range(0.5, 20)) = 3
        _Accel        ("Fall Acceleration", Range(1, 6)) = 3
        _Swirl        ("Swirl Turns (during pull)", Range(-2, 2)) = 0.5
    }

    SubShader
    {
        // 잘라 내기(clip)는 불투명 범위(AlphaTest 큐)로 그린다
        // → Opaque Texture 에 찍혀 01 렌즈 너머로도 보인다
        Tags { "RenderType" = "TransparentCutout" "Queue" = "AlphaTest" "RenderPipeline" = "UniversalPipeline" }

        // 구멍 사이로 안쪽 면이 보여야 하므로 양면으로 그린다
        Cull Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "../Shared/BlackHoleCommon.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseColor;
            float  _Threshold;
            float  _AutoPlay;
            float  _CycleSpeed;
            float  _NoiseScale;
            float  _EdgeWidth;
            float4 _EdgeColor;
            float  _FormDuration;
            float  _PullStart;
            float  _PullDuration;
            float  _ChunkScale;
            float  _Accel;
            float  _Swirl;
        CBUFFER_END

        // 한 바퀴 안의 진행 시간(0~1)
        float Life() { return BH_LoopThreshold(_Threshold, _AutoPlay, _CycleSpeed, _Time.y); }

        // 이 덩어리의 흡입 진행도. 덩어리 노이즈를 가파르게 깎아 덩어리 단위로 출발 시점을 정한다.
        // 정점과 픽셀이 '변형 전 오브젝트 좌표'로 똑같이 계산한다.
        float PullProgress(float3 positionOS)
        {
            float delay = smoothstep(0.3, 0.7, BH_DissolveNoise(positionOS * _ChunkScale + 23.7));
            return BH_CollapseProgress(Life(), _PullStart, _PullDuration, delay);
        }

        // 정점 단계: 흡입 진행도만큼 중심(구의 중심)으로 끌어당기면서
        //           오브젝트 위쪽 축을 기준으로 돌린다 → 나선을 그리며 빨려 든다
        //   회전 = (흡입 구간 전체가 함께 점점 빨리 도는 양) + (중심에 거의 다 온 덩어리만 더 도는 양)
        //   덩어리마다 각도가 크게 다르면 경계가 옆으로 찢겨 판처럼 늘어나므로,
        //   덩어리별 회전은 반지름이 이미 작아진 뒤(진행도^4)에만 붙인다.
        float3 SwirlAxisWS() { return normalize(TransformObjectToWorldDir(float3(0, 1, 0))); }
        float  SwirlAngle(float3 positionOS)
        {
            float field = saturate((Life() - _PullStart) / max(1.0 - _PullStart, 1e-3));
            float chunk = pow(PullProgress(positionOS), _Accel);
            return _Swirl * TWO_PI * (field * field + chunk * chunk * chunk * chunk);
        }

        float3 CollapsedWS(float3 positionOS)
        {
            float3 centerWS = BH_CenterWS();
            float3 pulled = BH_CollapseVertex(TransformObjectToWorld(positionOS), centerWS, PullProgress(positionOS), _Accel);
            return centerWS + BH_SwirlRotate(pulled - centerWS, SwirlAxisWS(), SwirlAngle(positionOS));
        }

        float3 SwirledNormalWS(float3 positionOS, float3 normalOS)
        {
            return BH_SwirlRotate(TransformObjectToWorldNormal(normalOS), SwirlAxisWS(), SwirlAngle(positionOS));
        }

        // 픽셀 단계: 원본 디졸브와 같은 '노이즈 < 기준' 잘라 내기 + smoothstep 경계 띠
        //   기준(cut) = max(생성 구간 기준 1→0, 흡입 진행도 0→1)
        // 반환값: 경계 띠(0~1)
        float ClipDissolve(float3 positionOS)
        {
            float noise = BH_DissolveNoise(positionOS * _NoiseScale);
            float cut = max(BH_FormCut(Life(), _FormDuration), PullProgress(positionOS)) * 1.01;
            clip(noise - cut);
            // 원본과 같이 기준이 0 이면(온전한 표면) 빛나지 않게 한다
            return (1.0 - smoothstep(cut, cut + _EdgeWidth, noise)) * saturate(cut * 20.0);
        }
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionOS : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS   : TEXCOORD2;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionWS = CollapsedWS(v.positionOS.xyz);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                o.positionOS = v.positionOS.xyz;
                o.normalWS   = SwirledNormalWS(v.positionOS.xyz, v.normalOS);
                return o;
            }

            float4 frag(Varyings i, FRONT_FACE_TYPE face : FRONT_FACE_SEMANTIC) : SV_Target
            {
                float edge = ClipDissolve(i.positionOS);

                // 램버트 + 받는 그림자 + 환경광 (뒷면은 법선을 뒤집는다)
                float3 n = normalize(i.normalWS);
                n = IS_FRONT_VFACE(face, n, -n);
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(i.positionWS));
                float  ndl = saturate(dot(n, mainLight.direction));
                float3 lit = _BaseColor.rgb * (mainLight.color * ndl * mainLight.shadowAttenuation + SampleSH(n));

                // 경계 띠는 발광 색으로 바꾼다 (조명과 무관하게 빛남)
                return float4(lerp(lit, _EdgeColor.rgb, edge), 1.0);
            }
            ENDHLSL
        }

        // 그림자에도 같은 변형과 잘라 내기를 적용한다
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
            struct Varyings   { float4 positionCS : SV_POSITION; float3 positionOS : TEXCOORD0; };

            Varyings vert(Attributes v)
            {
                Varyings o;
                float3 posWS = CollapsedWS(v.positionOS.xyz);
                float3 nWS = SwirledNormalWS(v.positionOS.xyz, v.normalOS);
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
                o.positionOS = v.positionOS.xyz;
                return o;
            }
            half4 frag(Varyings i) : SV_Target { ClipDissolve(i.positionOS); return 0; }
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
            struct Varyings   { float4 positionCS : SV_POSITION; float3 positionOS : TEXCOORD0; };
            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformWorldToHClip(CollapsedWS(v.positionOS.xyz));
                o.positionOS = v.positionOS.xyz;
                return o;
            }
            half frag(Varyings i) : SV_Target { ClipDissolve(i.positionOS); return i.positionCS.z; }
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
            struct Varyings   { float4 positionCS : SV_POSITION; float3 positionOS : TEXCOORD0; float3 normalWS : TEXCOORD1; };
            Varyings vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformWorldToHClip(CollapsedWS(v.positionOS.xyz));
                o.positionOS = v.positionOS.xyz;
                o.normalWS = SwirledNormalWS(v.positionOS.xyz, v.normalOS);
                return o;
            }
            half4 frag(Varyings i) : SV_Target
            {
                ClipDissolve(i.positionOS);
                return half4(NormalizeNormalPerPixel(i.normalWS), 0.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
