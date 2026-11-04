import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import { StudyDocumentImport } from './study/StudyDocumentImport.tsx';
import './styles.css';

const root = document.getElementById('root');
if (!root) throw new Error('Bex root element is missing.');
createRoot(root).render(<StrictMode><App DocumentImport={StudyDocumentImport} /></StrictMode>);
