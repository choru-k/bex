import { MAX_EXCERPT, MAX_SOURCE_TITLE, parseSource } from './model.ts';
import type { PolicyStorage, StudySource } from './model.ts';

/** User-entered excerpts only. No imports, fetches, embedding service, or book retrieval. */
export interface StudySection { id: string; label: string; excerpt: string }
export interface StudyMaterial { id: string; title: string; sections: StudySection[] }
export interface StudyLibrary { version: 1; materials: StudyMaterial[] }
export interface StudySelection { materialID: string; sectionID: string }
export type StudyLoadResult = { status: 'empty' | 'loaded' | 'invalid' | 'unavailable'; library: StudyLibrary };
export const STUDY_STORAGE_KEY = 'bex.study-excerpts.v1';
export const MAX_STUDY_MATERIALS = 20;
export const MAX_STUDY_SECTIONS = 20;
export const MAX_STUDY_CHARACTERS = 120_000;
export const MAX_STUDY_SERIALIZED = 1_000_000;
const invalidMessage = '자료 형식 또는 보관 한도를 확인하세요. 자료 20개, 자료별 단원 20개, 전체 발췌문 120,000자까지입니다.';
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const only = (value: Record<string, unknown>, keys: string[]) =>
  Object.keys(value).every(key => keys.includes(key));
const validID = (value: unknown): value is string => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(value);
const invalid = (): never => { throw new Error(invalidMessage); };
export const emptyStudyLibrary = (): StudyLibrary => ({ version: 1, materials: [] });

/** Strict allowlist: saved library cannot smuggle writing, credentials, requests, or active selection. */
export function parseStudyLibrary(value: unknown): StudyLibrary {
  if (!record(value) || !only(value, ['version', 'materials']) || value.version !== 1 ||
      !Array.isArray(value.materials) || value.materials.length > MAX_STUDY_MATERIALS) return invalid();
  const materialIDs = new Set<string>();
  let characterCount = 0;
  const materials = value.materials.map((item): StudyMaterial => {
    if (!record(item) || !only(item, ['id', 'title', 'sections']) || !validID(item.id) ||
        materialIDs.has(item.id) || typeof item.title !== 'string' || !item.title.trim() ||
        item.title.length > MAX_SOURCE_TITLE || !Array.isArray(item.sections) ||
        item.sections.length > MAX_STUDY_SECTIONS) return invalid();
    materialIDs.add(item.id);
    const title = item.title.trim();
    const sectionIDs = new Set<string>();
    const sections = item.sections.map((section): StudySection => {
      if (!record(section) || !only(section, ['id', 'label', 'excerpt']) || !validID(section.id) ||
          sectionIDs.has(section.id) || typeof section.label !== 'string' || !section.label.trim() ||
          section.label.length > MAX_SOURCE_TITLE || typeof section.excerpt !== 'string' ||
          !section.excerpt.trim() || section.excerpt.length > MAX_EXCERPT) return invalid();
      sectionIDs.add(section.id);
      characterCount += section.excerpt.length;
      if (characterCount > MAX_STUDY_CHARACTERS) return invalid();
      return { id: section.id, label: section.label.trim(), excerpt: section.excerpt };
    });
    return { id: item.id, title, sections };
  });
  return { version: 1, materials };
}

/** Reject unknown targets rather than silently updating another material. All edits return copies. */
function changeMaterial(library: StudyLibrary, id: string, change: (material: StudyMaterial) => StudyMaterial): StudyLibrary {
  const validated = parseStudyLibrary(library);
  if (!validated.materials.some(material => material.id === id)) throw new Error('자료를 찾지 못했습니다. 다시 선택하세요.');
  return parseStudyLibrary({ ...validated, materials: validated.materials.map(material => material.id === id ? change(material) : material) });
}
export function addStudyMaterial(library: StudyLibrary, id: string, title: string): StudyLibrary {
  const validated = parseStudyLibrary(library);
  return parseStudyLibrary({ ...validated, materials: [...validated.materials, { id, title, sections: [] }] });
}
export function renameStudyMaterial(library: StudyLibrary, id: string, title: string): StudyLibrary {
  return changeMaterial(library, id, material => ({ ...material, title }));
}
export function removeStudyMaterial(library: StudyLibrary, id: string): StudyLibrary {
  const validated = parseStudyLibrary(library);
  if (!validated.materials.some(material => material.id === id)) throw new Error('자료를 찾지 못했습니다. 다시 선택하세요.');
  return { ...validated, materials: validated.materials.filter(material => material.id !== id) };
}
export function addStudySection(library: StudyLibrary, materialID: string, section: StudySection): StudyLibrary {
  return changeMaterial(library, materialID, material => ({ ...material, sections: [...material.sections, section] }));
}
export function updateStudySection(library: StudyLibrary, materialID: string, section: StudySection): StudyLibrary {
  return changeMaterial(library, materialID, material => {
    if (!material.sections.some(item => item.id === section.id)) throw new Error('단원을 찾지 못했습니다. 다시 선택하세요.');
    return { ...material, sections: material.sections.map(item => item.id === section.id ? { ...section } : item) };
  });
}
export function removeStudySection(library: StudyLibrary, materialID: string, sectionID: string): StudyLibrary {
  return changeMaterial(library, materialID, material => {
    if (!material.sections.some(section => section.id === sectionID)) throw new Error('단원을 찾지 못했습니다. 다시 선택하세요.');
    return { ...material, sections: material.sections.filter(section => section.id !== sectionID) };
  });
}

/** Selection is session-only and bounded to exactly one attributed excerpt. Never concatenate books. */
export function selectedStudySource(library: StudyLibrary, selection: StudySelection | null): StudySource | null {
  if (selection === null) return null;
  const validated = parseStudyLibrary(library);
  const material = validated.materials.find(item => item.id === selection.materialID);
  const section = material?.sections.find(item => item.id === selection.sectionID);
  return material && section ? parseSource({ title: material.title, section: section.label, excerpt: section.excerpt }) : null;
}

/** Call only from an explicit restore action. Loading does not select a source or enable saving. */
export function loadStudyLibrary(storage: PolicyStorage): StudyLoadResult {
  let raw: string | null;
  try { raw = storage.getItem(STUDY_STORAGE_KEY); }
  catch { return { status: 'unavailable', library: emptyStudyLibrary() }; }
  if (raw === null) return { status: 'empty', library: emptyStudyLibrary() };
  try {
    if (raw.length > MAX_STUDY_SERIALIZED) return { status: 'invalid', library: emptyStudyLibrary() };
    return { status: 'loaded', library: parseStudyLibrary(JSON.parse(raw)) };
  } catch { return { status: 'invalid', library: emptyStudyLibrary() }; }
}
/** Writes only the strict library shape, never selection, user draft, results, or learning policy. */
export function saveStudyLibrary(storage: PolicyStorage, library: StudyLibrary): boolean {
  try {
    const raw = JSON.stringify(parseStudyLibrary(library));
    if (raw.length > MAX_STUDY_SERIALIZED) return false;
    storage.setItem(STUDY_STORAGE_KEY, raw);
    return true;
  } catch { return false; }
}
export function clearStudyLibrary(storage: PolicyStorage): boolean {
  try { storage.removeItem(STUDY_STORAGE_KEY); return true; } catch { return false; }
}
